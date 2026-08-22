-- Fuel: how far a tank goes, and where you buy another one.
--
-- ═══ WHAT THIS IS FOR, IN THE OWNER'S WORDS ═══
--
--   "It is exactly the case of 'a vehicle must not be a permanent advantage' -
--    that's exactly what we're trying to accomplish."   -- owner, 2026-08-21
--
-- #193 §4 is the arithmetic underneath that sentence: a vehicle gives the late
-- storm phases 60-70% slack, and NEITHER of the two `metersPerSec = 9.0` values
-- in config/storm.lua may be lowered to compensate without culling the player on
-- foot. So the only lever left is on the vehicle side, and this file is it.
--
-- ═══ THE UNIT IS METRES ═══
--
--   "Meters would be best as well."   -- owner, same comment
--
-- Not seconds of engine time. Idling at a POI costs nothing, sitting in a car as
-- cover costs nothing, and a cross-map run costs a tank. See the header of
-- br_lib/shared/fuel_solve.lua for the rest of that argument; everything below
-- is written in metres, and the ONE conversion to the vehicle's own litres
-- happens in BR.FuelSolve.tankLevel so the in-vehicle gauge reads correctly.

BR = BR or {}
BR.Config = BR.Config or {}

-- ═══════════════════════════════════════════════════════════════════════════
-- HOW BIG A TANK IS, AND WHY IT IS THAT NUMBER
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE RULE, VERBATIM:
--
--   "Our fuel consumption rate should be such that 1 trip across the map should
--    require 2 fuel stops."   -- owner, 2026-08-21, #195
--
-- ─── 1. HOW BIG IS THE MAP ───────────────────────────────────────────────────
--
-- BR.Config.Storm.mapAABB is the playable bounds -- "the LAND we want fights to
-- happen on", storm.lua's own words -- and it is the only authored description
-- of the map's size anywhere in the tree. Read from there rather than restated
-- here, so a change to the bounds moves this number with it instead of leaving
-- two disagreeing constants, which is this project's signature failure.
--
--     width    = 4500 - (-3600)  =  8,100 m
--     height   = 8000 - (-3600)  = 11,600 m
--     diagonal = sqrt(8100^2 + 11600^2) = 14,148 m
--
-- The diagonal is what "a trip across the map" means: corner to corner is the
-- longest journey the playable area contains.
--
-- ─── 2. WHAT "TWO STOPS" PINS DOWN ───────────────────────────────────────────
--
-- Start full, fill to full at every stop. A journey of D metres on a tank of T
-- covers T metres per tankful, so it needs ceil(D/T) tankfuls and therefore
-- ceil(D/T) - 1 stops. Two stops means ceil(D/T) = 3, which means
--
--     D/3  <=  T  <  D/2
--     4,716 m  <=  T  <  7,074 m
--
-- A BAND, NOT A NUMBER. The owner's rule does not name one value and cannot:
-- anything inside that band satisfies it exactly, and the whole point of writing
-- the derivation down is that the next person can re-run it when the AABB moves
-- rather than inheriting a constant with no argument attached.
--
-- ─── 3. WHICH VALUE INSIDE THE BAND, AND THE ONE ASSUMPTION IT PAYS FOR ──────
--
-- The diagonal is a STRAIGHT LINE and nobody drives one. A real crossing follows
-- roads, so the ground actually covered is k * D for some detour factor k > 1,
-- and the two-stop band in terms of k is
--
--     kD/3  <=  T  <  kD/2
--
-- Solved the other way -- for which k a given T still produces two stops:
--
--     T = 5,000 m  ->  k in [0.71, 1.06)     two stops only on an almost
--                                            perfectly straight run
--     T = 6,000 m  ->  k in [0.85, 1.27)     <-- CHOSEN
--     T = 7,000 m  ->  k in [0.99, 1.48)     three stops the moment the route
--                                            is even slightly shorter than the
--                                            full diagonal
--
-- 6,000 m is the value whose band straddles k = 1 with room on both sides: it
-- gives two stops for a route flown straight down the diagonal AND for one that
-- wanders 27% further than that. The alternatives are each tight against one
-- edge, which means the rule breaks on the first honest playtest in one
-- direction or the other.
--
-- ─── 4. SANITY, IN UNITS A PLAYER WOULD RECOGNISE ────────────────────────────
--
--     a tank at 25 m/s                     240 s  -- four minutes of driving
--     as a share of a match (1,315 s)      18%
--     median POI-to-POI hop (461 m)        ~13 hops
--     #195's opening guess                 3,000 m, which is FOUR stops
--
-- The issue's own starting number is doubled here, and that is the owner's
-- answer overriding the issue body: 3,000 m was proposed against no refuelling
-- at all, where the tank has to be a whole match's allowance. With stations on
-- the map the tank is a leg, not a budget.
--
-- ─── 5. WHAT IS NOT MODELLED, SAID PLAINLY ───────────────────────────────────
--
--   * the detour to reach a station is not in the arithmetic above. Stations sit
--     on roads and a route across the map passes several, but a player who has
--     to double back pays for it out of the same tank.
--   * hills. Consumption is HORIZONTAL distance (see BR.FuelSolve.travelled),
--     so a climb is charged as its footprint.
--   * the vehicle. A Bison and a Sultan drain identically per metre. #195 lists
--     `fPetrolConsumptionRate` as a per-model knob and this deliberately does
--     not use it: a range budget that varies by model is a second balance table
--     nobody has asked for yet.

local AABB = BR.Config.Storm and BR.Config.Storm.mapAABB or nil

--- The map's corner-to-corner distance, in metres.
---
--- DERIVED, NOT TYPED. If the playable bounds move, the number the tank is
--- justified against moves with them, and tools/test_fuel.lua re-checks the
--- two-stop rule against whatever comes out. A hardcoded 14148 would go stale
--- silently the first time somebody widened the map.
---
--- A LOCAL WITH A PUBLIC WRAPPER BELOW, rather than a new BR.Config.* name of
--- its own. The map's size is config/map.lua's and config/storm.lua's business
--- and neither of them exposes it; a fuel file is not the place to introduce a
--- general map helper that other subsystems would then start depending on.
--- @return number
local function mapDiagonal()
    if not AABB then return 0.0 end
    local w = AABB.max.x - AABB.min.x
    local h = AABB.max.y - AABB.min.y
    return math.sqrt(w * w + h * h)
end

BR.Config.Fuel = {
    --- The whole feature, on one switch.
    ---
    --- OFF MEANS THE SERVER TRACKS NOTHING AND THE CLIENT DRAWS NOTHING -- not
    --- "tracks it but stops enforcing". A half-live fuel model is worse than
    --- none, because the ledger keeps draining while nobody can see it and the
    --- first thing anyone notices is a car that will not start.
    enabled = true,

    --- A full tank, in metres of ground.
    ---
    --- SEE THE DERIVATION ABOVE. It is chosen inside the band 4,716..7,074 that
    --- the owner's "two stops per crossing" rule defines, at the point whose
    --- tolerance for road detours is widest.
    tankMetres = 6000.0,

    --- Seconds of holding the interact key to fill an empty tank.
    ---
    ---   "...which should take ~10 seconds to fill gradually"
    ---                                          -- owner, 2026-08-21
    ---
    --- THE OWNER'S NUMBER, not a guess. It is also the clock the REPAIR runs on
    --- -- see `repairFraction` -- so a full fill and a full repair finish
    --- together, which is what makes a stop a single decision rather than two.
    refuelSeconds = 10.0,

    --- How much of a vehicle's health a WHOLE tank of pumping puts back.
    ---
    ---   "When stopping for fuel ... the vehicle health should be restored."
    ---                                          -- owner, 2026-08-21
    ---
    --- ═══ WHAT THE OWNER DID NOT SAY, AND THE READING TAKEN ═══
    ---
    --- They did not say whether the repair is partial or total, nor whether it
    --- finishes with the fuel. The reading here is: A FULL FILL IS A FULL
    --- REPAIR, AND THE TWO RUN ON THE SAME CLOCK. So a driver who holds for the
    --- whole ten seconds drives away with a full tank and an undamaged car, and
    --- one who lets go after three seconds gets 30% of both.
    ---
    --- The argument is the sentence the owner gave the whole feature: a station
    --- has to be a MEANINGFUL STOP. Tying the repair to the same hold makes it
    --- one decision with one cost -- ten seconds standing still, in the open, at
    --- a place everyone else can see on their map -- rather than a free bonus
    --- attached to something you had to do anyway.
    ---
    --- ONE VALUE, NOT A SCATTERED CONSTANT. The per-second rate is derived from
    --- this and `refuelSeconds` below, and client/fuel.lua applies whatever the
    --- server grants; there is no second number anywhere.
    ---
    --- 1.0 means a full tank of pumping restores the full 0..1000 health range.
    --- 0.5 would mean a stop is a half-repair and damage accumulates across a
    --- match, which is a real and different game -- it is one edit away.
    repairFraction = 1.0,

    --- How close the VEHICLE has to be to a station to REFUEL.
    ---
    --- Measured from the authored station coordinate, which is a forecourt
    --- centre rather than a specific pump -- so this has to cover the whole
    --- apron, not a parking space.
    ---
    --- ═══ THIS IS NO LONGER WHAT DECIDES WHETHER THE PROMPT DRAWS ═══
    ---
    --- It was, and the first playtest said so:
    ---
    ---   "The DUI draws way too far away from the pumps. We need to be like
    ---    10ft from the pumps or less."   -- owner, 2026-08-22
    ---
    --- `promptRadius` below is that number and the plate is gated on it now.
    --- THIS ONE IS DELIBERATELY UNCHANGED: the owner confirmed refuelling works,
    --- and the server -- which re-derives every claim in a pump message -- has no
    --- pump coordinates to test against and cannot be given any, because
    --- GET_CLOSEST_OBJECT_OF_TYPE reads the STREAMED world and a server streams
    --- nothing. So the wide radius stays where the authority is and the narrow
    --- one lives on the client, which is the only side that can see a pump.
    stationRadius = 30.0,

    --- How far a player may be from a vehicle and still ask what it holds.
    ---
    --- THE ANSWER IS A SMALL PIECE OF INFORMATION AND THIS IS WHAT KEEPS IT
    --- LOCAL. Without a bound, a client could ask about every network id in the
    --- world and learn which cars are dry -- see server/fuel.lua's ask handler.
    --- Wide enough to cover the entry animation from any door, and nothing more.
    askRadius = 12.0,

    --- Metres per second above which a sample-to-sample step is disbelieved.
    ---
    --- A TELEPORT FILTER, NOT AN ANTICHEAT. The samples are the server's own.
    --- What produces an impossible step is `/brtp`, a recycled entity handle, or
    --- a vehicle streaming back in somewhere else -- and charging one of those
    --- empties a full tank in a single tick. Deliberately far above the fastest
    --- land vehicle in the game (~67 m/s) rather than tuned close to it: a cap
    --- that trims real driving makes fuel free at speed.
    maxSpeedMps = 120.0,

    --- Ceiling on the number of vehicles the server tracks at once.
    ---
    --- The keys arrive from the world. A vehicle enters the registry only by
    --- being sat in, so the live set is bounded by how many cars the players in
    --- a match have actually used -- but "48 players hopping cars in the city
    --- for twenty minutes" is a real shape and this is what stops it growing
    --- without limit. Past the cap the least recently occupied row is dropped,
    --- and the car it belonged to reads full again.
    maxTracked = 512,

    --- How long an unoccupied vehicle keeps its tank.
    ---
    --- LONGER THAN A ROTATION ON PURPOSE. A car left at one POI while its driver
    --- fights at the next must still be dry when they walk back to it -- that is
    --- the feature. This bounds the table over a twenty-minute match; it is not
    --- meant to expire state anybody is still using.
    idleTtlMs = 300000,

    --- Server -> client push policy. See server/fuel.lua's pushTo().
    ---
    --- `pushFraction` is a fraction of a TANK, so 0.005 of 6,000 m is 30 m --
    --- about 1.2 seconds of driving at 25 m/s, and far below anything a needle
    --- can show. Going dry and changing vehicle both push immediately whatever
    --- these say.
    pushFraction    = 0.005,
    pushHeartbeatMs = 2000,

    --- The refuel hold, from both ends.
    ---
    --- `pumpSendMs`   how often the CLIENT repeats its "still holding" while the
    ---                key is down.
    --- `pumpStepMs`   the ceiling the SERVER puts on a single grant. Above
    ---                pumpSendMs so an ordinary hold is never short-changed by a
    ---                dropped message, and small enough that a player who sends
    ---                one message and walks away gets a third of a second of
    ---                fuel rather than a tankful.
    --- `pumpFloorMs`  the server drops messages arriving faster than this
    ---                without doing any work. Not a security bound -- the clock
    ---                already is one, see BR.FuelSolve.grantMs -- purely a cap
    ---                on what a flood can cost in natives.
    pumpSendMs  = 250,
    pumpStepMs  = 400,
    pumpFloorMs = 80,

    --- Client-side bookkeeping.
    ---
    --- `askThrottleMs` one question per network id per second, so standing
    ---                 between two cars does not become a message loop.
    --- `clientTtlMs`   how long the client remembers a reading it was pushed.
    ---                 Losing one costs an ask, and asking is what makes the
    ---                 answer current.
    askThrottleMs = 1000,
    clientTtlMs   = 60000,

    --- The pump prompt.
    ---
    --- `promptRadius` how close the VEHICLE has to be to the pump prop before
    ---                the plate is drawn at all.
    --- `promptLift`   metres above the pump prop the plate floats.
    --- `promptScale`  passed straight to BR.Dui.drawWorld.
    ---
    --- ═══ 3.0 IS THE OWNER'S NUMBER, CONVERTED AND NOT ROUNDED UP ═══
    ---
    ---   "We need to be like 10ft from the pumps or less."
    ---                                          -- owner, 2026-08-22
    ---
    --- Ten feet is 3.048m. Rounded DOWN to 3.0 rather than up, because the
    --- sentence has "or less" in it: the owner named a ceiling, not a target.
    ---
    --- ═══ WHAT IT IS MEASURED FROM, WHICH IS THE THING TO KNOW BEFORE
    ---     CHANGING IT ═══
    ---
    --- From GET_ENTITY_COORDS ON THE VEHICLE -- roughly the middle of the car --
    --- to the pump prop's own origin. So the BODYWORK is nearer than this number
    --- by about half a car width, and a driver parked alongside a pump measures
    --- something like 2 to 3m here rather than the nought-point-something their
    --- eyes report.
    ---
    --- THAT MAKES 3.0 THE TIGHT END OF THE PLAUSIBLE RANGE, and it is the one
    --- value in this change that cannot be checked without a live server. If the
    --- plate turns out not to appear for a car parked square at a pump, this
    --- line is the whole fix -- and `/brfuel` prints the live distance and this
    --- radius side by side so the next number is measured rather than guessed.
    --- Everything above `promptRadius` and below `stationRadius` is the gap
    --- described at `stationRadius`: refuelling works, silently.
    promptRadius = 3.0,
    promptLift   = 1.4,
    promptScale  = 1.6,

    --- The controls that live on E in a vehicle, and both have to be held down.
    ---
    --- 86 is INPUT_VEH_HORN, keyboard E, controller L3.
    ---
    --- ═══ 351 IS THE ONE THAT WOULD HAVE BEEN MISSED ═══
    ---
    --- INPUT_VEH_ROCKET_BOOST IS ALSO ON E, and on L3. Suppressing only the
    --- horn means a player refuelling a boost-capable DLC car fires its rocket
    --- boost instead of honking -- which is worse than the bug being fixed, and
    --- is a real fault a shipping resource had to patch rather than a
    --- hypothetical. Both are disabled together and neither is optional.
    ---
    --- Named here rather than written into client/fuel.lua as bare numbers, for
    --- the reason config/weapons.lua gives about hashes: a magic number in a
    --- file nobody edits is a magic number nobody can check.
    hornControls = { 86, 351 },

    --- The two engine-side switches, set once per client.
    ---
    --- ═══ THIS PAIR IS WHAT MAKES THE STALL REAL, AND THE FIRST DRAFT OF THIS
    ---     FEATURE WOULD HAVE SHIPPED WITHOUT IT ═══
    ---
    --- The owner's expectation was "If you use SetVehicleFuelLevel and go down
    --- to 0, the game handles that on it's own. The vehicle will stall."
    ---
    --- IT DOES NOT, BY DEFAULT. FiveM's own implementation has exactly one call
    --- site that cuts an engine for fuel, inside ProcessFuelConsumption, and
    --- that function's first statement is `if (!g_isFuelConsumptionOn) return;`
    --- -- a flag that DEFAULTS TO FALSE and is only set by
    --- SET_FUEL_CONSUMPTION_STATE. SET_VEHICLE_FUEL_LEVEL itself writes a float
    --- and flips a "tank empty" bit; it never touches the engine. So writing 0
    --- with consumption off moves a needle and nothing else.
    ---
    --- Turning consumption ON would normally hand the drain back to the engine,
    --- which is exactly the client-authoritative model #195 rejected. The
    --- multiplier is what resolves that: the platform's own words are "If 0 - it
    --- practically means that fuel will not be consumed."
    ---
    --- So the engine is enrolled as a STALL ENFORCER and nothing else. It ticks,
    --- subtracts zero, sees a tank at zero, and cuts the engine -- every tick,
    --- so restarting a dry car cuts it again. The number itself only ever moves
    --- because the server said so.
    ---
    --- BOTH ARE GLOBAL AND BOTH RESET ON RESOURCE RESTART, which is why
    --- client/fuel.lua sets them on every resource start rather than once.
    consumptionState      = true,
    consumptionMultiplier = 0.0,

    --- How the stations appear on the map.
    ---
    --- `name` IS THE ONLY STRING THIS FEATURE INVENTS, and it exists because
    --- BR.Native.blipName requires one: "EVERY BLIP WE MAKE NEEDS ONE. A blip
    --- with no name inherits whatever GTA calls that sprite by default." It is
    --- a factual noun and no other copy is proposed anywhere in this feature --
    --- the standing rule is that UI text is the owner's wording.
    ---
    --- SPRITE 361 IS A JERRY CAN, NOT A PETROL PUMP, and that is not a mistake
    --- -- it is the whole available choice. GTA HAS NO GAS-STATION OR
    --- FUEL-PUMP BLIP SPRITE. The complete list of fuel-ish sprites in the game
    --- is 349 radar_gas_grenade, 361 radar_jerry_can, 415 radar_weapon_jerrycan
    --- and 922 radar_weapon_tear_gas, and 361 is the only one of the four that
    --- is not a weapon. (Vanilla GTA does not blip petrol stations at all, which
    --- is why no sprite was ever drawn for one.) Colour 5 is yellow.
    blip = {
        sprite = 361,
        colour = 5,
        scale  = 0.7,
        name   = 'Gas Station',
    },

    --- Pump prop models, for anchoring the prompt on the actual pump.
    ---
    --- ═══ THE ANSWER TO THE OWNER'S QUESTION ═══
    ---
    ---   "A DUI is perfect for this, anchored at the gas pump if possible, but
    ---    I'm not sure we have coords for the pump props."
    ---
    --- WE DO NOT, and no published dataset of pump PROP coordinates was found --
    --- every list that circulates is of station centres, which is what
    --- `stations` below holds. But a coordinate table was never the only way to
    --- get one. GET_CLOSEST_OBJECT_OF_TYPE asks the streamed world where the
    --- nearest object of a given model is, and by the time the prompt is drawn
    --- the player is parked on top of it -- so client/fuel.lua asks the engine
    --- instead, and gets the real prop at its real position, including at
    --- stations nobody has ever transcribed.
    ---
    --- HASHES ARE NOT PRECOMPUTED HERE, unlike config/weapons.lua's and
    --- config/vehicles.lua's, and the difference is that those two are compared
    --- against values the ENGINE reports and so must match its normalisation.
    --- These are only ever handed BACK to a native as a lookup key, which
    --- accepts the string form directly on the client.
    pumpModels = {
        'prop_gas_pump_1a',
        'prop_gas_pump_1b',
        'prop_gas_pump_1c',
        'prop_gas_pump_1d',
        'prop_gas_pump_old2',
        'prop_gas_pump_old3',
        'prop_vintage_pump',
    },

    --- How far from the vehicle to look for one, and how often to look again.
    pumpSearchRadius = 25.0,
    pumpRefreshMs    = 3000,

    --- The petrol stations.
    ---
    --- ═══ WHERE THESE CAME FROM ═══
    ---
    --- PROVENANCE IS RECORDED BECAUSE THE DATA IS NOT OURS. tools/verify.sh's
    --- `vendored third-party` gate asserts four things of a vendored RESOURCE --
    --- licence kept, version recorded, patch log matching the source, and the
    --- thing actually reaching the box. This is a coordinate table rather than a
    --- resource, so that gate does not reach it and there is no VENDOR.json to
    --- write; what the gate is FOR still applies, and the two items that
    --- survive the translation are recorded here in prose:
    ---
    ---   SOURCE   see the block immediately below.
    ---   LICENCE  see the same block.
    ---
    --- The owner named the source: "Use `frfuel` as an inspiration resource,
    --- which also includes coords for all the gas stations." It is INSPIRATION
    --- rather than a dependency -- nothing in this tree loads it, no code is
    --- shared with it, and it is not installed. The DATA below is copied, and
    --- that is what needs a notice.
    ---
    ---   SOURCE   thers/FRFuel, dist/GasStations.json (29 station centres).
    ---            https://github.com/thers/FRFuel
    ---            https://raw.githubusercontent.com/thers/FRFuel/master/dist/GasStations.json
    ---   LICENCE  MIT. The notice it requires, reproduced in full:
    ---
    ---     Copyright 2017 Alexander Kukhta
    ---
    ---     Permission is hereby granted, free of charge, to any person
    ---     obtaining a copy of this software and associated documentation files
    ---     (the "Software"), to deal in the Software without restriction,
    ---     including without limitation the rights to use, copy, modify, merge,
    ---     publish, distribute, sublicense, and/or sell copies of the Software,
    ---     and to permit persons to whom the Software is furnished to do so,
    ---     subject to the following conditions:
    ---
    ---     The above copyright notice and this permission notice shall be
    ---     included in all copies or substantial portions of the Software.
    ---
    ---     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    ---     EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    ---     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    ---     NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
    ---     BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
    ---     ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    ---     CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    ---     SOFTWARE.
    ---
    --- ═══ THE THREE SOURCES THAT WERE REJECTED, AND WHY ═══
    ---
    --- Naming them so nobody re-derives this decision, and so nobody "improves"
    --- the list from one of them later:
    ---
    ---   InZidiuZ/LegacyFuel    28 stations, GPL-3.0. Copyleft, and this repo
    ---   overextended/ox_fuel   27 stations, GPL-3.0. is not GPL.
    ---   DurtyFree/gta-v-data-dumps  the BEST dataset by a distance -- 131 real
    ---                          pump props with rotations, extracted from the
    ---                          game files rather than walked in-game -- and it
    ---                          has NO LICENCE FILE AT ALL. The best data and
    ---                          the weakest position, so it is not used.
    ---
    --- ═══ WHAT THESE COORDINATES ARE, AND WHAT WAS CHECKED ═══
    ---
    --- They are FORECOURT CENTRES, walked in game rather than extracted, so
    --- each sits within a metre or two of a pump rather than on one. That is why
    --- `stationRadius` is generous and why the prompt is anchored on a pump prop
    --- found at runtime rather than on these numbers.
    ---
    --- CHECKED HERE, arithmetically, against the map this gamemode plays on --
    --- these are somebody else's numbers and they are used because they were
    --- checked, not because they were published:
    ---
    ---   * all 29 fall inside BR.Config.Storm.mapAABB. None is off-map.
    ---   * the worst gap between neighbours is 1,707 m (the west coast, north
    ---     of Fort Zancudo).
    ---   * THE NUMBER THAT MATTERS: the furthest any point of the playable land
    ---     area sits from a station is about 3,216 m, which is just over HALF a
    ---     6,000 m tank. So a full tank always reaches a pump from anywhere on
    ---     the map, which is what makes running dry a decision rather than an
    ---     accident.
    ---
    --- NOT CHECKED, AND IT NEEDS A PLAYTEST: that each coordinate lands on
    --- drivable ground rather than inside geometry, and that `z` is the
    --- forecourt rather than a roof. Only the blip and the prompt fallback use
    --- `z` at all -- the radius test is 2-D -- so a wrong one is cosmetic, but
    --- it is a real unknown and `/brfuel` on the client prints which station it
    --- thinks you are at.
    ---
    --- IDS ARE NUMBERS, NOT PLACE NAMES. The source carries no names, GTA's
    --- brands (RON, Xero Gas, Globe Oil, LTD) are not published against
    --- coordinates anywhere, and inventing thirty place names would be inventing
    --- thirty facts.
    stations = {
        { id = 'gas01', x =    49.419, y = 2778.793, z =  58.044 },
        { id = 'gas02', x =   263.895, y = 2606.463, z =  44.983 },
        { id = 'gas03', x =  1039.958, y = 2671.134, z =  39.551 },
        { id = 'gas04', x =  1207.260, y = 2660.175, z =  37.900 },
        { id = 'gas05', x =  2539.685, y = 2594.192, z =  37.945 },
        { id = 'gas06', x =  2679.858, y = 3263.946, z =  55.241 },
        { id = 'gas07', x =  2005.055, y = 3773.887, z =  32.404 },
        { id = 'gas08', x =  1687.156, y = 4929.392, z =  42.078 },
        { id = 'gas09', x =  1701.314, y = 6416.028, z =  32.764 },
        { id = 'gas10', x =   179.857, y = 6602.839, z =  31.868 },
        { id = 'gas11', x =   -94.462, y = 6419.594, z =  31.490 },
        { id = 'gas12', x = -2554.996, y = 2334.402, z =  33.078 },
        { id = 'gas13', x = -1800.375, y =  803.662, z = 138.651 },
        { id = 'gas14', x = -1437.622, y = -276.748, z =  46.208 },
        { id = 'gas15', x = -2096.243, y = -320.287, z =  13.169 },
        { id = 'gas16', x =  -724.619, y = -935.163, z =  19.214 },
        { id = 'gas17', x =  -526.020, y = -1211.003, z = 18.185 },
        { id = 'gas18', x =   -70.215, y = -1761.792, z = 29.534 },
        { id = 'gas19', x =   265.648, y = -1261.309, z = 29.293 },
        { id = 'gas20', x =   819.654, y = -1028.846, z = 26.403 },
        { id = 'gas21', x =  1208.951, y = -1402.567, z = 35.224 },
        { id = 'gas22', x =  1181.381, y =  -330.847, z = 69.317 },
        { id = 'gas23', x =   620.843, y =   269.101, z = 103.090 },
        { id = 'gas24', x =  2581.321, y =   362.039, z = 108.469 },
        { id = 'gas25', x =  1785.363, y =  3330.372, z = 41.382 },
        { id = 'gas26', x =  -319.690, y = -1471.610, z = 30.030 },
        { id = 'gas27', x =   174.880, y = -1562.450, z = 28.740 },
        { id = 'gas28', x =  1246.480, y = -1485.450, z = 34.900 },
        { id = 'gas29', x =   -66.330, y = -2532.570, z =  6.140 },
    },
}

--- Metres of fuel per second of holding the pump.
---
--- DERIVED FROM refuelSeconds RATHER THAN AUTHORED BESIDE IT, so the two can
--- never disagree. Authoring both is exactly the shape of the bug this project
--- keeps paying for -- one value written down twice with nothing comparing them.
BR.Config.Fuel.refuelMetresPerSec =
    BR.Config.Fuel.tankMetres / math.max(0.001, BR.Config.Fuel.refuelSeconds)

--- The map, corner to corner, in metres.
--- @return number
function BR.Config.Fuel.mapDiagonal() return mapDiagonal() end

--- GTA's vehicle health scale. Body, engine and petrol-tank health all run
--- 0..1000, and `SetVehicleBodyHealth` and friends take that unit directly.
BR.Config.Fuel.healthMax = 1000.0

--- Health points restored per second of holding the pump.
---
--- DERIVED FROM repairFraction AND refuelSeconds, so a full fill is exactly a
--- full repair and the two can never disagree. This is the "one configurable
--- value" the repair has: change `repairFraction` and this follows.
BR.Config.Fuel.repairPerSecond =
    (BR.Config.Fuel.healthMax * BR.Config.Fuel.repairFraction)
    / math.max(0.001, BR.Config.Fuel.refuelSeconds)

--- How many refuelling stops a corner-to-corner crossing costs.
---
--- THE OWNER'S RULE, EVALUATED RATHER THAN ASSERTED. tools/test_fuel.lua fails
--- the build when this stops answering 2, which is what makes the derivation in
--- the header a live claim rather than a comment somebody will stop believing.
--- @param detour number|nil  road-length multiplier over the straight line
--- @return integer
function BR.Config.Fuel.stopsPerCrossing(detour)
    local d = mapDiagonal() * (tonumber(detour) or 1.0)
    return BR.FuelSolve.stopsFor(d, BR.Config.Fuel.tankMetres)
end
