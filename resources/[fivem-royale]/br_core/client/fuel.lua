-- The gauge, the pump and the station blips.
--
-- ═══ THIS FILE IS A RENDERER. THE NUMBER LIVES ON THE SERVER ═══
--
-- br_core/server/fuel.lua owns a metre count per vehicle and pushes it here.
-- Everything below either DRAWS that number or ASKS for it; nothing here
-- decides it, and the one message that changes it (BR.Net.FUEL_PUMP) is
-- re-derived from scratch at the far end -- which vehicle, which seat, which
-- station, how many milliseconds -- so what this file actually asserts is "a
-- key is down", the only fact in the interaction that lives on a keyboard.
--
-- ═══ WHY THE GAUGE HAS TO BE WRITTEN HERE AT ALL ═══
--
-- SET_VEHICLE_FUEL_LEVEL is a client native and its value DOES NOT SYNC --
-- citizenfx/fivem#3310, open since April 2025. Refuel a car and the passenger
-- beside you sees the old number. That is normally quoted as a bug; here it is
-- the reason this file exists in the shape it does. There is no "set it once on
-- the server" to reach for, so every client that needs a correct gauge writes
-- its own copy, from the one number the server keeps.
--
-- The owner asked for exactly this:
--
--   "Option B2 is best here, but it should trigger SetVehicleFuelLevel so the
--    in-vehicle fuel-gauge works."
--   "If you use SetVehicleFuelLevel and go down to 0, the game handles that on
--    it's own. The vehicle will stall. Thing is - that needs to carry over if
--    someone else comes up to the vehicle and tries to drive it."
--
-- ═══ HOW THE STALL CARRIES OVER, IN ORDER ═══
--
--   1. a player walks up to a car somebody drained and starts the entry
--      animation. This file sees GetVehiclePedIsEntering and ASKS the server
--      for that network id -- about a second before the seat is taken.
--   2. the answer lands and is written to `known`.
--   3. the moment the ped is in a seat, `fuel.apply` writes the level. On a dry
--      car that is 0, and the engine does the stalling itself.
--
-- WHAT IS NOT COVERED, STATED RATHER THAN GLOSSED: a player who reaches a seat
-- WITHOUT the entry animation -- a teleport, a warp, a shuffle across from the
-- passenger seat -- gets the level on the first `fuel.apply` pass after the
-- server's next sample instead, which is up to about 350ms of engine that
-- should not have turned over. It is bounded, it is one tick band plus one
-- sample interval, and closing it entirely would mean asking about every
-- vehicle near the player rather than the one they are climbing into.

BR = BR or {}
BR.Fuel = {}

local F = BR.Config.Fuel

--- What the server has told us, keyed by network id. [netId] = { f, m, at }
---
--- BOUNDED BY WHAT WE ASK ABOUT, which is the vehicle under the player and the
--- one they are climbing into. It is swept rather than trusted to stay small,
--- because a long match in a city is a lot of cars.
local known = {}

--- When we last asked about a network id, so a car we are standing beside is
--- asked about once rather than sixty times a second.
local asked = {}

--- Station blips, while the player is in a vehicle. [index] = blip handle
local blips = {}

--- The station the player is currently parked at, and the pump prop we found
--- to hang the prompt on.
---
--- `dist` is the last measured metres from the vehicle to that anchor, and
--- `stationDist` the metres from the vehicle to the authored forecourt centre.
--- Both are kept for `/brfuel` and for nothing else: `promptRadius` and
--- `refuelRadius` are the two values in this feature that cannot be checked
--- outside a live server, and a debug line that prints each live distance beside
--- its radius is what makes the next number measured rather than guessed.
--- `scan` is the sweep in progress, or nil between sweeps. See resolvePump.
local at = {
    station = nil, pump = nil, pumpAt = 0,
    px = nil, py = nil, pz = nil, dist = nil, stationDist = nil,
    scan = nil,
}

--- Forget the pump anchor entirely.
---
--- THE ANCHOR COORDINATES ARE CLEARED HERE AND THEY WERE NOT CLEARED ANYWHERE
--- BEFORE, which was a real bug rather than tidying. The three teardown sites
--- and the change-of-station branch all reset `pump` and left `px/py/pz`
--- standing, so a driver who resolved a pump at one station and then parked at
--- a station whose pumps did not stream kept the FIRST station's pump as their
--- anchor -- `local px = at.px or station.x` reads whatever is there. The
--- documented fallback ("FALLS BACK TO THE STATION CENTRE") could therefore
--- never happen once any pump had ever been found in the session.
---
--- An in-flight sweep goes too. It carries a running best measured from a
--- vehicle position at a different station, and finishing it after a move would
--- commit that answer here.
local function forgetPump()
    at.pump, at.pumpAt = nil, 0
    at.px, at.py, at.pz = nil, nil, nil
    at.scan = nil
end

--- Is the prompt page currently showing OUR plate?
---
--- A BOOLEAN NOW, WHERE IT USED TO BE THE METRES ON THE LABEL. The label is a
--- constant string, so there is nothing left to compare but shown-ness -- and
--- one message on the way in and one on the way out is the whole traffic this
--- prompt generates, down from one per hundred metres of fill.
---
--- STARTS false RATHER THAN nil so the first frame off a forecourt is not a
--- hide message for a plate that was never up.
local promptShown = false

--- And which of the two labels it is currently showing.
---
--- SEPARATE FROM promptShown because the plate now has three states, not two:
--- down, up saying "Hold to refuel", up saying "Currently fueling". Folding
--- them into one variable is how the switch stops being sent.
local promptFueling = false

--- Last time a pump request went out, for the send cadence.
local pumpedAt = 0

--- Did a native declared BOOL say yes?
---
--- THE `didHit` IDIOM, FOR THE FIFTH-ISH TIME IN THIS CODEBASE. A FiveM native
--- declared BOOL hands Lua a number on some builds and a boolean on others, and
--- IN LUA `0` IS TRUTHY. `IsPedInAnyVehicle` and `DoesBlipExist` are both
--- declared BOOL and both are load-bearing here: a `0` read as true would have
--- this file drawing a fuel prompt for a player standing in a field.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Is the fuel model switched on?
--- @return boolean
local function enabled()
    return F ~= nil and F.enabled == true and (tonumber(F.tankMetres) or 0) > 0
end

--- The network id of a vehicle handle, or nil.
--- @param veh integer|nil
--- @return integer|nil
local function netOf(veh)
    if not veh or veh == 0 then return nil end
    local ok, nid = pcall(NetworkGetNetworkIdFromEntity, veh)
    if not ok then return nil end
    nid = math.tointeger(tonumber(nid))
    -- ZERO IS EXPLICIT. It is what the engine answers for an entity that is not
    -- networked -- a client-side vehicle like the Battle Bus or #191's
    -- ambulance -- and `0` is truthy in Lua, so a bare `if nid then` would take
    -- it and then ask the server about a vehicle the server has never heard of.
    if nid == nil or nid == 0 then return nil end
    return nid
end

--- Ask the server what this vehicle's tank holds.
---
--- THROTTLED PER NETWORK ID rather than globally: standing between two cars and
--- looking back and forth must not suppress the second question, because the
--- answer to it is what decides whether the engine turns over.
--- @param netId integer
--- @param now integer
local function ask(netId, now)
    local last = asked[netId]
    if last and (now - last) < (tonumber(F.askThrottleMs) or 1000) then return end
    asked[netId] = now
    TriggerServerEvent(BR.Net.FUEL_ASK, { n = netId })
end

-- ---------------------------------------------------------------------------
-- The gauge
-- ---------------------------------------------------------------------------

--- Write the server's number onto the local vehicle.
---
--- ═══ THE TANK VOLUME IS READ FROM THE HANDLING, NOT ASSUMED ═══
---
--- SET_VEHICLE_FUEL_LEVEL is in the vehicle's own units, and `fPetrolTankVolume`
--- differs per model. The server sends a FRACTION for exactly that reason: the
--- ledger is a range in metres and a range does not change because the tank is
--- bigger, so the same 3km reads as the same needle position on a Sultan and on
--- a Bison.
---
--- A ZERO VOLUME IS LEFT ALONE, AND THAT IS GTA'S OWN RULE RATHER THAN OURS.
--- Vehicles with a zero tank -- bicycles -- have infinite fuel by construction
--- in the engine, which ignores whatever it is told. Writing to them would be
--- harmless and pointless; skipping is one comparison and says why.
--- ═══ LITRES, NOT PERCENT, AND THE ECOSYSTEM DISAGREES WITH THE DOCS ═══
---
--- FiveM's own documentation fills a tank with
--- `SetVehicleFuelLevel(veh, GetVehicleHandlingFloat(veh, 'CHandlingData',
--- 'fPetrolTankVolume'))` and prints "out of %.3f liters", so the unit is
--- litres over 0..fPetrolTankVolume. Two of the most-deployed fuel resources
--- (ox_fuel, LegacyFuel) instead clamp to 0..100 and write that -- which
--- "works" only because the native does NO CLAMPING AT ALL; its whole body is a
--- raw float write plus one tank-empty bit.
---
--- THE CHOICE IS LOAD-BEARING HERE AND NOT ELSEWHERE, which is why it is
--- written down. This file deliberately enables the engine's own fuel system
--- (see the resource-start block at the bottom) so that a zero tank stalls the
--- car, and that system reads the level in litres against
--- `fPetrolConsumptionRate`. Writing a 0..100 number into a 65-litre tank would
--- put the two conventions in the same variable.
---
--- @param veh integer
--- @param frac number
--- @return boolean applied
local function applyLevel(veh, frac)
    -- A VEHICLE THAT DOES NOT USE FUEL IS LEFT ALONE. GTA gives bicycles -- and
    -- anything else with `fPetrolTankVolume` of 0 -- infinite fuel by
    -- construction and ignores what it is told, so writing to them is
    -- meaningless. Asked through the native where there is one, because it knows
    -- the rule better than a volume test does.
    if DoesVehicleUseFuel then
        local okU, uses = pcall(DoesVehicleUseFuel, veh)
        if okU and not didHit(uses) then return false end
    end

    local ok, vol = pcall(GetVehicleHandlingFloat, veh,
                          'CHandlingData', 'fPetrolTankVolume')
    if not ok then return false end
    vol = tonumber(vol) or 0.0
    if vol <= 0.0 then return false end

    local level = BR.FuelSolve.clamp(frac, 1.0) * vol
    pcall(SetVehicleFuelLevel, veh, level + 0.0)
    return true
end

--- Put health back into a vehicle, gradually.
---
--- ═══ A SEAM FOR #194, AND IT IS NAMED SO IT DOES NOT BECOME A COLLISION ═══
---
--- Vehicle damage is #194's subject. This file models NONE of it: it never
--- reads a damage rule, never decides what hurt a car, and does exactly one
--- thing to vehicle health -- adds the points the SERVER granted for a validated
--- pump hold. If #194 introduces a server-side vehicle-health model, this
--- function is the one place that has to change, and it changes to read that
--- model's number instead of the three engine ones.
---
--- Undo the damage a player can SEE, all at once.
---
--- ═══ THE OWNER ADDED THIS ON 2026-08-22 ═══
---
---   "The gas stations should be repairing cosmetic damage as well, which means
---    a fill up will fix everything in one go."
---
--- ═══ FOUR NATIVES, THREE NAMESPACES, AND THEY ARE NOT INTERCHANGEABLE ═══
---
--- Each was read out of citizenfx/natives rather than remembered, because the
--- obvious guess -- "SetVehicleFixed does everything" -- is wrong twice:
---
---   SET_VEHICLE_FIXED               0x115722B1B9C14C1C. The "repair the car"
---   (VEHICLE)                       native: deformation, smashed glass, burst
---                                   tyres, hanging doors, bullet holes.
---                                   ITS DOCUMENTED LIMIT IS THE ONE THAT
---                                   MATTERS HERE: "If the vehicle's engine's
---                                   broken then you cannot fix it with this
---                                   native." See the ordering note below.
---
---   SET_VEHICLE_DEFORMATION_FIXED   0x953DA1E1B12C0491. Deformation ONLY --
---   (VEHICLE)                       "the vehicle health doesn't improve". This
---                                   is what the file already called, and it is
---                                   kept rather than replaced: it is the one
---                                   call documented to reset dents with no
---                                   side-effects, and it costs nothing to
---                                   follow the broader native with the precise
---                                   one.
---
---   WASH_DECALS_FROM_VEHICLE        0x5B712761429DBC14. IN THE **GRAPHICS**
---   (GRAPHICS)                      NAMESPACE, NOT VEHICLE -- which is exactly
---                                   the kind of detail that turns into a nil
---                                   global and a suspended callback. Scuffs
---                                   and scrape marks are DECALS painted on the
---                                   bodywork, not deformation, so
---                                   SetVehicleFixed does not touch them. This
---                                   is the owner's "scratches".
---
--- NOT CALLED, AND THAT IS A DECISION RATHER THAN AN OMISSION:
---
---   SET_VEHICLE_DIRT_LEVEL  would wash the car. DIRT IS NOT DAMAGE -- it
---                           accumulates from driving in the rain, not from
---                           being shot -- and the owner asked for cosmetic
---                           DAMAGE. A petrol station that also valets the car
---                           is a thing nobody asked for. One line if they want
---                           it: `SetVehicleDirtLevel(veh, 0.0)`, range 0..15.
---   SET_VEHICLE_TYRE_FIXED  per-tyre, and FIX_VEHICLE_WINDOW per-window. Both
---                           are already covered by SetVehicleFixed; looping
---                           indices would be more code for the same result.
---
--- ═══ THE ORDER IS LOAD-BEARING ═══
---
--- The engine health is restored by applyRepair BEFORE this runs, because
--- SetVehicleFixed cannot fix a broken engine. With #213 making vehicles
--- genuinely destructible, cars will start arriving here with dead engines --
--- so a version of this that called SetVehicleFixed first and trusted it to do
--- the whole job would leave exactly the wrecks that most needed fixing.
---
--- ═══ ALL-OR-NOTHING, AND THAT IS THE ENGINE'S RULE, NOT A CHOICE ═══
---
--- There is no partial dent. Every native above is a reset -- none takes a
--- fraction, and GTA exposes no way to pop half a deformation out. So cosmetic
--- repair cannot ride the per-second clock the health pools ride, and it fires
--- at COMPLETION instead: the frame the body reaches full, which is the moment
--- the file already chose for the deformation pop and for the same reason
--- (doing it a tenth at a time reads as the car breathing).
---
--- THE PARTIAL RULE IS THEREFORE INTACT: a driver who lets go after three
--- seconds gets 30% of their health back and NO cosmetic repair, because their
--- body health did not reach full. They have to finish to get the paint back.
--- @param veh integer
local function fixCosmetic(veh)
    -- Every one of these is pcall'd for the reason /brfuel's header gives: an
    -- unknown binding THROWS, five throws suspend the callback, and a suspended
    -- callback is silent. WashDecalsFromVehicle in particular is the first
    -- GRAPHICS-namespace native this file has ever called.
    if SetVehicleFixed then pcall(SetVehicleFixed, veh) end
    if SetVehicleDeformationFixed then pcall(SetVehicleDeformationFixed, veh) end
    -- p1 is the wash strength; 1.0 is a full wash. The native takes a float and
    -- the `+ 0.0` is this codebase's habit of never handing an integer to one.
    if WashDecalsFromVehicle then pcall(WashDecalsFromVehicle, veh, 1.0 + 0.0) end
end

--- ALL THREE HEALTH POOLS, because "restored" with one of them left low is a car
--- that looks fine and dies to the next bump. Body is the panels, engine is
--- whether it runs, petrol tank is whether it catches fire.
---
--- THE COSMETIC PASS IS FIXED ONCE, AT THE TOP. Dents are visual and popping them
--- out a tenth at a time reads as the car breathing; doing it on the frame the
--- body reaches full reads as the repair finishing. See fixCosmetic for what
--- "cosmetic" turned out to mean in natives, and why the engine is restored
--- first.
--- @param veh integer
--- @param points number  health, on GTA's 0..1000 scale
local function applyRepair(veh, points)
    local cap = tonumber(F.healthMax) or 1000.0
    if not veh or veh == 0 or (tonumber(points) or 0) <= 0 then return end

    local function bump(getter, setter)
        if type(getter) ~= 'function' or type(setter) ~= 'function' then return 0 end
        local ok, cur = pcall(getter, veh)
        if not ok then return 0 end
        cur = tonumber(cur) or 0.0
        -- ENGINE HEALTH GOES NEGATIVE when a car is wrecked -- that is the
        -- engine's own encoding for "destroyed", not a bad read -- so the floor
        -- is applied here rather than trusting the value.
        if cur < 0.0 then cur = 0.0 end
        if cur >= cap then return cap end
        local want = math.min(cap, cur + points)
        pcall(setter, veh, want + 0.0)
        return want
    end

    -- ENGINE FIRST, AND THE ORDER IS NOT COSMETIC. SetVehicleFixed inside
    -- fixCosmetic is documented not to fix a broken engine, so the engine is
    -- put back by the explicit setter above it rather than left to a native
    -- that will decline.
    bump(GetVehicleEngineHealth, SetVehicleEngineHealth)
    bump(GetVehiclePetrolTankHealth, SetVehiclePetrolTankHealth)
    local body = bump(GetVehicleBodyHealth, SetVehicleBodyHealth)

    -- THE TRIGGER IS STILL THE BODY REACHING FULL, deliberately unchanged. It
    -- would read as tidier to require all three pools at full, but that hands
    -- the cosmetic repair a new way to never happen -- if any pool ever refuses
    -- to climb, the dents stay in forever -- and it is a regression on the one
    -- trigger that has already been played. The body is the pool the dents
    -- belong to anyway.
    if body >= cap then fixCosmetic(veh) end
end

-- ---------------------------------------------------------------------------
-- The two bars
-- ---------------------------------------------------------------------------

--- What the interface was last told, so an unchanged readout is not re-sent.
local lastBars = { show = nil, health = -1, fuel = -1, boost = -1 }

--- How healthy a vehicle is, 0..100.
---
--- ═══ THE WORST OF THE THREE, NOT THE BODY ALONE ═══
---
--- GTA keeps three separate 0..1000 pools and they fail in different ways:
--- body is the panels, engine is whether it runs at all, petrol tank is
--- whether it catches fire. A car with pristine bodywork and a 200-point engine
--- is a car about to stop, and a bar reading it off the body would show 100%
--- right up until it did.
---
--- ENGINE HEALTH GOES NEGATIVE when a vehicle is wrecked -- that is the engine's
--- own encoding rather than a bad read -- so it is floored before the minimum,
--- or a dead car would read as a healthy one with a strange number in it.
--- @param veh integer
--- @return number 0..100
local function healthPct(veh)
    local cap = tonumber(F.healthMax) or 1000.0
    local worst = cap

    local function pool(getter)
        if type(getter) ~= 'function' then return end
        local ok, v = pcall(getter, veh)
        if not ok then return end
        v = tonumber(v)
        if v == nil or v ~= v then return end
        if v < 0.0 then v = 0.0 end
        if v > cap then v = cap end
        if v < worst then worst = v end
    end

    pool(GetVehicleBodyHealth)
    pool(GetVehicleEngineHealth)
    pool(GetVehiclePetrolTankHealth)

    return (worst / cap) * 100.0
end

--- Tell the interface what to draw, on change only.
---
--- ═══ TWO BARS, NO WORDS ═══
---
---   "We need to develop some new health bars, using the same graphical style
---    as the existing ones. They should be for vehicle health and fuel level,
---    which are shown on all players' screens while in a vehicle, regardless of
---    which seat they're in."   -- owner, 2026-08-21
---
--- ANY SEAT: nothing below asks who is driving. A passenger reads the same two
--- bars the driver does.
---
--- ROUNDED BEFORE COMPARING, because a bar cannot show a fraction and float
--- churn would defeat the dedupe -- the same reason client/state.lua floors
--- stamina before it pushes it.
--- @param veh integer|nil  nil when the player is not in one
--- @param fuelFrac number|nil
local function pushBars(veh, fuelFrac)
    local show = veh ~= nil
    local health, fuel, boost = 0, 0, 0
    if show then
        health = math.floor(healthPct(veh) + 0.5)
        -- AN UNKNOWN TANK READS FULL, NOT EMPTY. This is the gap between
        -- sitting down and the server's answer arriving, and a bar that flashed
        -- empty for a tenth of a second every time somebody got into a car
        -- would be read as the car being dry.
        fuel = math.floor(BR.FuelSolve.clamp(fuelFrac or 1.0, 1.0) * 100.0 + 0.5)
        -- ═══ THE THIRD BAR RIDES THIS ENVELOPE RATHER THAN OPENING A SECOND ═══
        --
        --   "Good call - I meant to ask for a Boost bar."  -- owner, 2026-08-22
        --
        -- The boost meter belongs to client/boost.lua, which owns it and is
        -- declared above this file. Asked here, at call time, because this is the
        -- function that already dedupes and already decides when the vehicle
        -- strip is drawn at all -- and a second NUI channel carrying one number
        -- on its own cadence is how two surfaces that should agree stop agreeing.
        --
        -- NIL-GUARDED so the boost being switched off, or its file failing to
        -- load, costs a bar rather than the whole strip.
        boost = math.floor(
            ((BR.Boost and BR.Boost.meter and BR.Boost.meter()) or 100.0) + 0.5)
    end

    if show == lastBars.show and health == lastBars.health
       and fuel == lastBars.fuel and boost == lastBars.boost then
        return
    end
    lastBars.show, lastBars.health, lastBars.fuel, lastBars.boost =
        show, health, fuel, boost

    TriggerEvent('br:ui:sendLocal', BR.Nui.VEHICLE, {
        show = show, health = health, fuel = fuel, boost = boost,
    })
end

-- ---------------------------------------------------------------------------
-- Station blips
-- ---------------------------------------------------------------------------

--- WHO MAY SEE THE STATION BLIPS FROM THE SEAT THEY ARE IN.
---
--- ═══ THE RULE, IN TWO INSTRUCTIONS ═══
---
---   "Also, while in a vehicle (any seat), all gas stations should be shown as
---    blips on the map."                          -- owner, 2026-08-21, #195
---   "passengers should only see gas station blips if the driver is in the same
---    squad."                                     -- owner, 2026-08-22
---
--- THE SECOND NARROWS THE FIRST AND KEEPS ITS REASON INTACT. "Any seat" was
--- never about seats -- the case that made it worth having was a PASSENGER
--- NAVIGATING FOR THE DRIVER, and a passenger navigating for a stranger is not
--- that case. So the map still opens for the person doing the navigating; it no
--- longer opens for somebody who happens to have climbed into a car.
---
--- ═══ WHAT WAS SETTLED, SAID OUT LOUD ═══
---
---   THE DRIVER ALWAYS SEES THEM, whoever else is aboard and whatever match
---   this is. They are the one who has to reach a pump.
---   A PASSENGER SEES THEM ONLY WHEN THE DRIVER IS A SQUADMATE. Same squadId,
---   from the roster, which is the server's answer rather than this client's.
---   A SOLO PASSENGER IN A STRANGER'S CAR SEES NOTHING. There is no squad in a
---   solo match, so there is no squadmate the driver could be -- the rule
---   resolves to "not the driver, no blips" without needing to know the match
---   kind at all. The same line covers a squad match before squads are formed
---   and a player whose squad is gone: no squadId is not a squad of strangers,
---   it is nobody, and the conservative answer is the right one.
---   AN EMPTY DRIVER'S SEAT IS NOT A SQUADMATE. Sitting in the passenger seat
---   of a parked car with nobody at the wheel shows nothing, and the blips
---   appear the moment a squadmate takes it.
---
--- ═══ THE DRIVER CHANGING SEAT OR LEAVING MID-DRIVE COSTS NOTHING ═══
---
--- Because this is RE-DERIVED ON THE TICK BAND AND NEVER LATCHED, the same
--- shape as everything else in this file. There is no "the driver changed"
--- event to subscribe to and none is wanted: the seat is read fresh every 100
--- ms, so a squadmate bailing out takes the blips down within a tick and a
--- squadmate sliding into the driver's seat puts them back within a tick. No
--- transition has to be enumerated, so none can be forgotten -- which is the
--- same argument the not-in-a-vehicle branch below already makes for itself.
---
--- SHORT RANGE, which is what keeps a few dozen icons from becoming a wall. A
--- short-range blip is drawn on the PAUSE MAP always and on the minimap only
--- when the player is near it -- so "all gas stations show on the map" is true
--- in the place the player goes to plan a route, and the minimap stays a
--- minimap.
---
--- NAMED, BECAUSE EVERY BLIP WE MAKE MUST BE. BR.Native.blipName's own note:
--- "A blip with no name inherits whatever GTA calls that sprite by default --
--- so the courtesy loot markers announced themselves in the pause menu as
--- whatever heist the briefcase sprite was drawn for." The legend string is the
--- only text this feature invents and it is one factual noun; nothing else here
--- writes a word of prose.
--- THE PREDICATE ITSELF IS BR.FuelSolve.blipsVisibleTo, in br_lib, and it is
--- there rather than here for one reason: this file cannot be loaded by a test.
--- tools/test_fuel.lua says so at length at its `prompt.copy` block -- registering
--- frame-band callbacks and calling a dozen unstubbed natives at load makes it
--- readable only as TEXT -- so a rule written here would be pinned by grep and
--- nothing more. In br_lib it is executed, against every combination of seat,
--- squad and roster, by a suite that already loads that module.
---
--- Put every station on the map.
local function showBlips()
    if #blips > 0 then return end
    local b = F.blip or {}
    for i = 1, #F.stations do
        local s = F.stations[i]
        local blip = AddBlipForCoord(s.x + 0.0, s.y + 0.0, (tonumber(s.z) or 0.0) + 0.0)
        SetBlipSprite(blip, math.tointeger(tonumber(b.sprite)) or 1)
        SetBlipColour(blip, math.tointeger(tonumber(b.colour)) or 0)
        SetBlipScale(blip, (tonumber(b.scale) or 1.0) + 0.0)
        SetBlipAsShortRange(blip, true)
        BR.Native.blipName(blip, b.name or 'Gas Station')
        blips[#blips + 1] = blip
    end
end

--- Take them off again.
---
--- ENGINE BLIP HANDLES ARE RECYCLED, which client/storm.lua learned the
--- expensive way ("another system removing a stale handle can delete ours").
--- So every removal is guarded by DoesBlipExist and the table is emptied
--- whether or not the handles were still live.
local function hideBlips()
    for i = 1, #blips do
        if didHit(DoesBlipExist(blips[i])) then RemoveBlip(blips[i]) end
    end
    blips = {}
end

-- ---------------------------------------------------------------------------
-- The pump
-- ---------------------------------------------------------------------------

--- Find the pump prop nearest the vehicle, so the prompt hangs on the pump.
---
--- ═══ THE OWNER'S QUESTION, ANSWERED BY ASKING THE ENGINE INSTEAD ═══
---
---   "A DUI is perfect for this, anchored at the gas pump if possible, but I'm
---    not sure we have coords for the pump props."   -- owner, 2026-08-21
---
--- We do not, and no public dataset of pump PROP coordinates was found -- the
--- lists that circulate are station centres, which is what BR.Config.Fuel.
--- stations holds. But a coordinate table was never the only way to get one:
--- GET_CLOSEST_OBJECT_OF_TYPE asks the streamed world where the nearest object
--- of a given model is, and by the time this runs the player is parked on top
--- of it. That answer is better than a table would have been -- it is the
--- actual prop, at its actual position, including at stations added by a game
--- build nobody has transcribed.
---
--- CACHED, because it is one native call PER PUMP MODEL and there are several.
--- Re-resolved on `pumpRefreshMs` so backing up to the next pump moves the
--- prompt, and dropped entirely on leaving the station.
---
--- FALLS BACK TO THE STATION CENTRE. A station whose pumps are not streamed --
--- or a model list that has gone stale against a game build -- still has an
--- anchor rather than none at all.
---
--- SINCE THE PROMPT MOVED TO A THREE-METRE RADIUS THAT FALLBACK IS THINNER THAN
--- IT WAS, and it is worth saying so rather than leaving it to be discovered:
--- the authored coordinate is a forecourt CENTRE, so a car parked at a pump is
--- several metres from it and the plate may simply not appear. The refuel is
--- unaffected -- that is the station radius, and it is thirty metres. See the
--- gate in the pump loop.
--- @param x number
--- @param y number
--- @param z number
--- @param now integer
--- ═══ THIS RAN SEVEN GET_CLOSEST_OBJECT_OF_TYPE CALLS IN ONE FRAME, AND ON A
---     MISS IT RAN THEM ON EVERY FRAME FOREVER ═══
---
---   "Major client performance hits when at gas stations - what can we do about
---    that?"                                    -- owner, 2026-08-23
---
--- THIS FUNCTION IS THAT REPORT. Two faults, and the second is the one that
--- turns a stutter into a collapse:
---
---   1. SEVEN CALLS, ONE FRAME. `pumpModels` has seven entries and the old body
---      asked about all of them between two lines of the FRAME band.
---      GET_CLOSEST_OBJECT_OF_TYPE has no spatial index -- it walks the object
---      pool -- and Cfx.re's thread on it (forum.cfx.re/t/146715) measures
---      2-4ms per call. Seven is 14-28ms: one to two whole frames of a 60fps
---      budget, spent inside one callback, EVERY `pumpRefreshMs`. That alone is
---      a visible hitch every three seconds on every forecourt.
---
---   2. A MISS WAS NEVER CACHED. The old guard was
---
---          if at.pump and (now - at.pumpAt) < pumpRefreshMs then return end
---
---      -- it holds the answer only when there IS one. `at.pump` is nil the
---      moment the sweep fails, so the guard was false again on the very next
---      frame and the whole seven-call sweep ran again, at 60Hz, for as long as
---      the player stayed put. And a miss is not the rare case: the horn
---      suppression bubble is `stationRadius` (30m) while the search is
---      `pumpSearchRadius` (25m), so EVERY approach to EVERY station spends its
---      first stretch inside the radius that runs this and outside the radius
---      that can answer it -- and a station whose pump props are not in the
---      model list never answers at all, for the whole time the player is
---      parked on it.
---
--- ═══ WHAT IT DOES NOW: ONE MODEL PER PASS, AND A MISS IS AN ANSWER ═══
---
--- The sweep is incremental. Each pass asks about ONE model, keeps the running
--- best, and commits when it has been round the whole list -- so the cost in
--- any single frame is one call rather than seven, and `pumpScanStepMs` spaces
--- the passes so the seven are spread over ~700ms rather than seven frames.
---
--- The commit records `pumpAt` whether or not a pump was found, which is the
--- whole of fault 2: a station with no findable pump is now asked about once
--- every `pumpRefreshMs`, exactly like a station with one.
---
--- NOTHING VISIBLE CHANGES. The previous answer stays live for the whole sweep
--- -- the plate does not move or flicker while the next one is assembled -- and
--- the anchor is only re-read every `pumpRefreshMs` regardless. What the player
--- gets is the same plate, on the same pump, without the frame it used to cost.
--- @param x number
--- @param y number
--- @param z number
--- @param now integer
local function resolvePump(x, y, z, now)
    local models = F.pumpModels
    local reach  = tonumber(F.pumpSearchRadius) or 0.0
    if reach <= 0.0 or type(models) ~= 'table' or #models == 0 then return end

    local scan = at.scan
    if not scan then
        -- Idle: hold the committed answer -- FOUND OR NOT -- for the refresh
        -- interval. This single `or` is fault 2's fix.
        if (now - (at.pumpAt or 0)) < (tonumber(F.pumpRefreshMs) or 3000) then
            return
        end
        scan = { i = 1, bestD = math.huge, stepAt = 0 }
        at.scan = scan
    end

    -- ONE MODEL, AND NOT BEFORE THE STEP INTERVAL IS UP.
    if (now - scan.stepAt) < (tonumber(F.pumpScanStepMs) or 100) then return end
    scan.stepAt = now

    local name = models[scan.i]
    scan.i = scan.i + 1

    local ok, obj = pcall(GetClosestObjectOfType, x, y, z, reach,
                          name, false, false, false)
    if ok and obj and obj ~= 0 and didHit(DoesEntityExist(obj)) then
        local okc, c = pcall(GetEntityCoords, obj)
        if okc and c then
            local d = BR.Dist(x, y, c.x, c.y)
            if d < scan.bestD then
                scan.bestD = d
                scan.pump = obj
                scan.px, scan.py, scan.pz = c.x, c.y, c.z
            end
        end
    end

    -- Round the whole list: commit, and start the refresh clock.
    if scan.i > #models then
        at.scan   = nil
        at.pumpAt = now
        at.pump   = scan.pump
        -- A MISS CLEARS THE ANCHOR rather than leaving the last station's pump
        -- standing in it -- see forgetPump for what that bug looked like.
        at.px, at.py, at.pz = scan.px, scan.py, scan.pz
    end
end

--- The prompt page.
---
--- SHARED WITH THE CRATE AND THE REVIVE, deliberately, and dbno.lua wrote the
--- rule this follows: "One browser for every world prompt in the game, created
--- on whichever of the two asks first." A DUI is a whole CEF instance and a
--- fourth one for a prompt that is only ever up while parked at a pump would be
--- a browser per interaction.
---
--- THE ONE OVERLAP, NAMED RATHER THAN DISCOVERED: client/loot.lua takes its own
--- prompt down whenever the player is in a car (`canTake()` is false there and
--- loot.render clears on it), so the crate and the pump can never both be
--- writing. client/dbno.lua's revive does not check for a vehicle -- so a driver
--- parked at a pump within 1.5m of a downed teammate is two writers on one page,
--- and the visible result is the two labels alternating. It needs a body on the
--- forecourt to happen and it costs nothing when it does.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- What the plate says. The owner's words, and the whole of them.
---
--- ═══ IT USED TO BE THE METRES REMAINING, AND THE PLAYTEST THREW THAT OUT ═══
---
---   "The DUI is not helpful - it just says '6000m' etc. Instead it should say
---    'Hold to refuel'"   -- owner, 2026-08-22
---
--- VERBATIM AND NOTHING APPENDED. No metres, no key name in the sentence, no
--- progress line. The previous draft reasoned that a reading in the owner's unit
--- was the safest thing to put on a plate nobody had written copy for; the
--- reading was the complaint.
---
--- ═══ WHY IT IS THE `label` FIELD AND NOT `hint` ═══
---
--- The pattern this prompt shares with the crate and the revive is label = the
--- SUBJECT ("Assault Rifle", a teammate's name) and hint = the VERB PHRASE
--- ("Hold to open", "Hold to revive"), so the hint slot is where a sentence of
--- this shape belongs. It goes in `label` anyway, for two reasons:
---
---   * `#hint` in br_ui/dui/prompt.html is `text-transform: uppercase`. The
---     owner asked for "Hold to refuel" and that slot can only render
---     "HOLD TO REFUEL", which is not the string they wrote.
---   * `label` is the slot that was showing "6000m" -- the line the complaint is
---     about -- and leaving it empty would put the one thing the plate says in
---     the small dim line under a blank space.
---
--- There is no subject to put above it, because naming one would be inventing a
--- noun the owner has not written. If they ever give one, it goes in `label` and
--- this string moves down to `hint`; the plate already draws both.
local PROMPT_LABEL = 'Hold to refuel'

--- And what it says while the key is down.
---
---   "While holding the key, the DUI should change to say 'Currently fueling'"
---                                          -- owner, 2026-08-22
---
--- VERBATIM, INCLUDING THE SPELLING. "fueling" with one L is what they wrote;
--- this file does not correct the owner's copy to "fuelling", and a future
--- tidy-up that does is a change to UI text nobody asked for.
---
--- THE SAME SLOT AS THE OTHER ONE, AND FOR THE SAME REASON. `#hint` in
--- br_ui/dui/prompt.html is `text-transform: uppercase`, so that slot can only
--- ever render "CURRENTLY FUELING". Both strings live in `label` so both reach
--- the plate as written.
---
--- IT IS THE CLIENT'S KEY STATE THAT SWITCHES THIS, NOT A SERVER GRANT, and the
--- owner's wording is why: "WHILE HOLDING THE KEY". A plate that waited for the
--- server to confirm a grant would lag the keypress by a round trip and would
--- flicker back to "Hold to refuel" every time a message was dropped. The plate
--- describes what the player is doing; the ledger describes what they earned.
local PROMPT_LABEL_FUELING = 'Currently fueling'

--- Show or hide the pump prompt.
---
--- SENT ON CHANGE, WHICH IS NOW TWICE PER STOP. The label is a constant, so
--- there is nothing to update between the message that puts the plate up and the
--- one that takes it down.
---
--- THE KEY CAP STAYS, AND IT IS THE PATTERN RATHER THAN AN ADDITION TO THE
--- STRING. client/loot.lua and client/dbno.lua both pass `key` beside their
--- prompt copy, and the page draws it as a badge of its own -- it is not
--- appended to the sentence and does not change a character of it. Dropping it
--- would be a change to a thing that works, on a fix that was not about it.
--- NOW THREE MESSAGES PER STOP RATHER THAN TWO: up, switched to fueling, down.
--- The dedupe below is what keeps it to that -- the label only has two values,
--- so holding the key for ten seconds sends ONE message, not forty.
--- @param show boolean
--- @param fueling boolean|nil  is the interact key down right now?
local function setPrompt(show, fueling)
    show = (show == true)
    fueling = (fueling == true)
    -- A HIDDEN PLATE HAS NO LABEL, so `fueling` is not compared while hidden --
    -- otherwise letting go of the key off a forecourt would send a second hide
    -- message for a plate that is already down.
    if promptShown == show and (not show or promptFueling == fueling) then return end
    promptShown, promptFueling = show, fueling

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    local key = BR.Keys and BR.Keys.labelFor and BR.Keys.labelFor('brinteract') or nil
    BR.Dui.send(page, {
        t = 'prompt', show = true,
        label = fueling and PROMPT_LABEL_FUELING or PROMPT_LABEL,
        key = key,
        ring = false,
    })
end

-- ---------------------------------------------------------------------------
-- Loops
-- ---------------------------------------------------------------------------

--- Keep the local gauge equal to the ledger, and keep the blips honest.
---
--- TICK RATHER THAN FRAME. The number moves at the speed of a car, the server
--- pushes it about once a second, and writing it ten times a second is already
--- an order of magnitude more often than it changes. What the rate DOES buy is
--- the reassertion: a client that overwrites its own fuel level gets ours back
--- within 100ms, so the most a local write can be worth is a tenth of a second
--- of engine.
BR.Loop.register(BR.Loop.TICK, 'fuel.apply', function()
    if not enabled() then return end

    local ped = PlayerPedId()
    local now = GetGameTimer()

    -- THE CAR THEY ARE CLIMBING INTO, ASKED ABOUT BEFORE THE SEAT IS TAKEN.
    -- This is the whole of "the stall carries over": the entry animation runs
    -- for about a second, and one round trip fits inside it comfortably.
    local entering = GetVehiclePedIsEntering and GetVehiclePedIsEntering(ped) or 0
    if entering and entering ~= 0 then
        local nid = netOf(entering)
        if nid and not known[nid] then ask(nid, now) end
    end

    local inVeh = didHit(IsPedInAnyVehicle(ped, false))
    if not inVeh then
        -- ═══ EVERY EXIT FROM A VEHICLE PASSES THROUGH HERE ═══
        --
        -- Leaving on foot, being pulled out, the car exploding under you, dying
        -- in it, and being teleported out of it are the same fact from this
        -- line's point of view: the ped is not in a vehicle. So the bars come
        -- down, the blips come down and the prompt comes down in one place,
        -- rather than each transition needing to be enumerated and one of them
        -- being forgotten.
        --
        -- MID-FILL IS NOT A SPECIAL CASE EITHER. The fill lives in the server's
        -- ledger and is bounded by a held key; leaving the seat stops the key
        -- being held, the grants stop, and the tank keeps exactly what it was
        -- filled to. There is no progress to lose because there is no progress
        -- being accumulated anywhere but in the number itself.
        hideBlips()
        setPrompt(false)
        pushBars(nil, nil)
        at.station, at.dist, at.stationDist = nil, nil, nil
        forgetPump()
        return
    end

    local veh = GetVehiclePedIsIn(ped, false)

    -- THE SEAT RULE FOR THE BLIPS. See BR.Fuel.blipsVisibleTo for the owner's
    -- two instructions and everything that was settled between them.
    --
    -- READ HERE RATHER THAN INSIDE showBlips(), so the else-branch exists and
    -- has to be written. A visibility rule that only knows how to turn a thing
    -- ON leaves it on: a passenger whose squadmate gets out would keep every
    -- station on their map for the rest of the drive, and there is no event
    -- that would have taken them down.
    --
    -- pcall FOR THE SAME REASON THE PUMP'S SEAT READ HAS ONE, twenty lines
    -- below: GetPedInVehicleSeat is called on a vehicle handle that can go
    -- stale between this tick and the last, and a raise here would take the
    -- whole 10 Hz band with it.
    local okSeat, driver = pcall(GetPedInVehicleSeat, veh, -1)
    if okSeat and BR.FuelSolve.blipsVisibleTo(
            driver, ped, BR.State.me, BR.State.roster,
            BR.Squadmates and BR.Squadmates.pedOf)
    then
        showBlips()
    else
        hideBlips()
    end

    local nid = netOf(veh)
    if nid == nil then
        -- A non-networked vehicle -- the Battle Bus. The server has never heard
        -- of it and it has no tank here, so the fuel bar would be describing
        -- nothing. The bars stay down rather than reading full forever.
        --
        -- #191's AMBULANCE USED TO BE NAMED HERE AND IS NOT ONE OF THESE. It is
        -- networked now (the owner made it destructible on 2026-08-23, and only
        -- a networked vehicle can be shot by anybody else). It never reaches
        -- this function at all: the rescued player is ATTACHED to the stretcher
        -- rather than seated, so the vehicle read above finds nothing to ask
        -- about.
        setPrompt(false)
        pushBars(nil, nil)
        return
    end

    local rec = known[nid]
    if rec == nil then
        ask(nid, now)
        -- SHOWN WHILE THE ANSWER IS IN FLIGHT, with the tank reading full --
        -- see pushBars. The alternative is a strip that appears a fraction of a
        -- second after the door shuts, which reads as the HUD stuttering.
        pushBars(veh, nil)
        return
    end

    applyLevel(veh, rec.f)
    pushBars(veh, rec.f)
end)

--- The pump: horn suppression, the hold, and the prompt.
---
--- FRAME RATHER THAN TICK, and DisableControlAction is the whole reason --
--- a disable lasts exactly one frame, so anything that suppresses a control has
--- to run in this band. client/inventory.lua's suppression note is the same
--- shape and the same argument.
BR.Loop.register(BR.Loop.FRAME, 'fuel.pump', function()
    if not enabled() then return end

    local ped = PlayerPedId()
    if not didHit(IsPedInAnyVehicle(ped, false)) then return end

    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end

    -- THE DRIVER'S SEAT AND NOTHING ELSE -- the owner's rule, and the server
    -- re-checks it, so this is the half that decides what is DRAWN rather than
    -- what is allowed.
    local ok, driver = pcall(GetPedInVehicleSeat, veh, -1)
    if not ok or driver ~= ped then
        setPrompt(false)
        at.station, at.dist, at.stationDist = nil, nil, nil
        forgetPump()
        return
    end

    local okc, c = pcall(GetEntityCoords, veh)
    if not okc or c == nil then return end

    -- THE SECOND RETURN IS NOW READ. It is the metres from the vehicle to the
    -- authored forecourt centre, and it is what `refuelRadius` is measured
    -- against below -- the same test, on the same authored list, that the
    -- server will run on its own copy of this vehicle's position.
    local station, stationDist =
        BR.FuelSolve.stationNear(c.x, c.y, F.stations, F.stationRadius)
    if station == nil then
        setPrompt(false)
        at.station, at.dist, at.stationDist = nil, nil, nil
        forgetPump()
        return
    end

    local now = GetGameTimer()
    if at.station ~= station then
        at.station = station
        forgetPump()
    end

    -- ═══ THE HORN ═══
    --
    --   "...which should suppress the vehicle horn while pressed at a gas
    --    station since the default button is E, and that honks the horn."
    --                                          -- owner, 2026-08-21, #195
    --
    -- SUPPRESSED FOR THE WHOLE TIME THE PLAYER IS PARKED IN THE DRIVER'S SEAT
    -- AT A STATION, NOT ONLY WHILE THE KEY IS DOWN, and that is not a widening
    -- of the rule -- it is the only spelling of it that works. A disable takes
    -- effect for the frame it is issued in and cannot be applied retroactively,
    -- so waiting until the key reads as held means the engine has already had a
    -- frame in which the horn was live. The audible result of that is a chirp
    -- at the start of every refuel, which is precisely the thing being asked
    -- for the absence of.
    --
    -- The cost, stated: you cannot honk on a forecourt. The bubble is a few
    -- dozen metres wide and you have to be sitting still in it.
    --
    -- AND THE KEY IS STILL READ, because BR.Keys reads it through the raw layer
    -- and through IsDisabledControl* -- disabling a control does not stop the
    -- disabled variants from seeing it, which is the entire point of them.
    -- client/inventory.lua relies on the same property in four places.
    --
    -- TWO CONTROLS, NOT ONE, AND THE SECOND IS THE ONE THAT WOULD HAVE BEEN
    -- MISSED: INPUT_VEH_ROCKET_BOOST (351) is ALSO on E and on L3. Suppressing
    -- only the horn means a player refuelling a boost-capable DLC car launches
    -- it down the forecourt instead of honking, which is a worse bug than the
    -- one being fixed. See BR.Config.Fuel.hornControls.
    local hc = F.hornControls
    for i = 1, #hc do DisableControlAction(0, hc[i], true) end

    -- The prompt hangs on the pump when one can be found, and on the station
    -- otherwise. Resolved here rather than in the tick band because it needs
    -- the vehicle's position, which this pass already has.
    resolvePump(c.x, c.y, c.z, now)

    -- ═══ THE PLATE IS GATED ON THE PUMP, NOT ON THE STATION ═══
    --
    --   "The DUI draws way too far away from the pumps. We need to be like 10ft
    --    from the pumps or less."   -- owner, 2026-08-22
    --
    -- EVERYTHING ABOVE THIS LINE STILL RUNS ON THE STATION RADIUS, and the horn
    -- is the reason it has to. A driver who rolls onto a forecourt has to have
    -- E suppressed from the first frame -- a disable cannot be applied
    -- retroactively -- so the suppression bubble is the apron and the plate is
    -- the parking space. Two radii, two jobs, and only the smaller one moved.
    --
    -- THE ANCHOR IS WHATEVER resolvePump FOUND, so the test is against the pump
    -- prop when there is one and the authored forecourt centre when there is
    -- not. The fallback case is measured on the same three metres deliberately:
    -- one rule is easier to reason about than two, and a station whose pumps did
    -- not stream is rare enough that the honest answer -- no plate, refuelling
    -- still works -- beats a second radius nobody can see the effect of.
    local px = at.px or station.x
    local py = at.py or station.y

    local atPump
    atPump, at.dist = BR.FuelSolve.atPump(c.x, c.y, px, py,
                                          tonumber(F.promptRadius) or 0.0)
    at.stationDist = stationDist

    -- ═══ THE PLATE IS GATED ON BOTH RADII, AND THE SECOND ONE IS THE FIX ═══
    --
    --   "The distance for the DUI to draw is great, but for some reason I can
    --    still get gas further away from the pumps before the DUI is drawn.
    --    That's not okay."                    -- owner, 2026-08-22
    --
    -- The pump test is the one they liked and it is unchanged. What is added is
    -- the SERVER'S OWN TEST, run here as well: `refuelRadius` from the station
    -- centre. Drawing the plate on the conjunction is what makes the plate an
    -- honest advertisement of what the hold below will actually achieve --
    -- there is no longer a position where one is true and the other is not.
    --
    -- WHICH DIRECTION THIS FAILS IN, IF refuelRadius IS EVER SET TOO TIGHT: no
    -- plate and no fuel, at a station whose pumps sit unusually far from the
    -- authored centre. That is the same class of failure `promptRadius` already
    -- risks and it is the survivable one. The unsurvivable one -- a plate
    -- reading "Currently fueling" while the server refuses every message -- is
    -- precisely what gating on the server's own number prevents.
    local inReach = atPump
                    and stationDist <= (tonumber(F.refuelRadius) or 0.0)

    -- THE KEY, READ ONCE AND USED TWICE: it decides what the plate says and
    -- whether a message goes out, and reading it twice in one frame is how
    -- those two stop agreeing.
    local held = BR.Keys ~= nil and BR.Keys.isHeld ~= nil
                 and BR.Keys.isHeld('interact')
    setPrompt(inReach, held)

    if inReach then
        local pz = (at.pz or (tonumber(station.z) or c.z))
                   + (tonumber(F.promptLift) or 1.4)
        BR.Dui.drawWorld(promptPage(), px, py, pz, tonumber(F.promptScale) or 1.6)
    end

    -- ═══ THE HOLD, AND IT NOW SENDS NOTHING WHILE THE PLATE IS DOWN ═══
    --
    -- THIS ONE LINE IS THE WHOLE OF THE OWNER'S BUG. The send used to sit
    -- OUTSIDE the `inReach` test on the reasoning that the server re-derives
    -- eligibility anyway, so a client-side gate added nothing -- which was true
    -- about SECURITY and completely wrong about what the player experiences. It
    -- meant a hold anywhere within the station radius filled the tank with
    -- nothing on screen saying so, and that is what they are complaining about.
    --
    -- Gating the send on the plate makes the two the same event: if you can see
    -- it you can fill, and if you cannot see it nothing happens. The server's
    -- own test stays exactly where it was and is not weakened by this -- see
    -- BR.Config.Fuel.refuelRadius for the half of the fix that survives a
    -- client which ignores this line, and for what such a client actually gains.
    --
    -- One message every `pumpSendMs` for as long as the key is down, and the
    -- server decides what each one is worth from the wall clock. Sending faster
    -- earns nothing (BR.FuelSolve.grantMs), which is why this cadence can be a
    -- comfort rather than a security boundary.
    if not inReach then return end
    local nid = netOf(veh)
    if nid == nil then return end
    if not held then return end
    if (now - pumpedAt) < (tonumber(F.pumpSendMs) or 250) then return end
    pumpedAt = now
    TriggerServerEvent(BR.Net.FUEL_PUMP, { n = nid })
end)

--- Forget vehicles we have not seen in a while.
---
--- The table is keyed on network ids that arrive from the world, so it grows
--- with the number of cars a player has been near over a twenty-minute match.
--- Nothing depends on an old entry: the server is asked again the moment one is
--- missing, and asking is what makes the answer current.
BR.Loop.register(BR.Loop.SLOW, 'fuel.forget', function()
    if not enabled() then return end
    local now = GetGameTimer()
    local ttl = tonumber(F.clientTtlMs) or 60000
    for nid, rec in pairs(known) do
        if (now - rec.at) > ttl then known[nid] = nil end
    end
    for nid, t in pairs(asked) do
        if (now - t) > ttl then asked[nid] = nil end
    end
end)

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.FUEL_SET)
AddEventHandler(BR.Net.FUEL_SET, function(d)
    if type(d) ~= 'table' then return end
    local nid = math.tointeger(tonumber(d.n))
    if nid == nil then return end

    local prev = known[nid]
    known[nid] = {
        f  = tonumber(d.f) or 1.0,
        m  = tonumber(d.m) or 0,
        at = GetGameTimer(),
    }

    -- The rest of this handler is only about the vehicle THIS player is sitting
    -- in: a repair grant and an ignition are both things you do to the car you
    -- are in, and a push about any other car is just a number for the bars.
    local ped = PlayerPedId()
    if not didHit(IsPedInAnyVehicle(ped, false)) then return end
    local veh = GetVehiclePedIsIn(ped, false)
    if netOf(veh) ~= nid then return end

    if d.r then applyRepair(veh, tonumber(d.r) or 0.0) end

    -- ═══ THE ENGINE DOES NOT COME BACK ON ITS OWN ═══
    --
    -- FiveM's fuel system cuts an engine at zero and has NO code path that
    -- restarts one -- putting fuel back only clears the tank-empty bit. So a
    -- player who ran dry, refuelled, and was left sitting in a silent car would
    -- have every reason to think refuelling was broken.
    --
    -- ONLY ON THE EMPTY->NON-EMPTY EDGE, and only for the driver. Asserting the
    -- ignition on every push would fight a player who deliberately switched
    -- their own engine off, and would do it ten times a second.
    if prev and prev.f <= 0.0 and (tonumber(d.f) or 0.0) > 0.0 then
        local okSeat, driver = pcall(GetPedInVehicleSeat, veh, -1)
        if okSeat and driver == ped and SetVehicleEngineOn then
            -- `disableAutoStart = false`: we WANT the ped to keep it running.
            pcall(SetVehicleEngineOn, veh, true, false, false)
        end
    end
end)

--- The repair kit landed (#228).
---
--- ═══ THE SAME applyRepair THE PUMP GRANT USES, AND THAT IS THE WHOLE POINT ═══
---
--- The petrol station already restores the three health pools in the order they
--- have to go in -- engine before SetVehicleFixed, which is documented not to
--- fix a broken one -- pops the deformation out and washes the bullet decals
--- off. A second implementation of that would be a second place for the ordering
--- rule to be got wrong, and the one that got it wrong would be the one nobody
--- had played. So this handler does no repairing of its own: it resolves the
--- vehicle, checks it is the one the server ruled on, and hands the grant to the
--- same function FUEL_SET hands its `r` to.
---
--- IT IS NOT EXPOSED ON BR.Fuel, deliberately. Both callers are in this file, so
--- there is nothing to share across one; a public entry point would be a way for
--- some future file to apply vehicle health without the ordering note above it.
---
--- ═══ WHY THIS IS A FULL REPAIR AND THE PUMP'S IS NOT ═══
---
--- Nothing here decides that. The server grants BR.Config.Fuel.healthMax, which
--- is enough to cap every pool -- and the cosmetic pass fires on the frame the
--- BODY reaches full, which it now does on the first call. A driver who lets go
--- of the pump early still gets their partial and keeps their dents, by exactly
--- the same rule, because their grant was smaller.
---
--- ═══ THE THREE THINGS IT REFUSES, AND ALL THREE ARE THE SAME CASE ═══
---
--- A player who left the seat in the time this message took to arrive. Not in a
--- vehicle, in a different vehicle, or in a vehicle whose network id is not the
--- one the server named: nothing happens. The kit is already spent by then --
--- the server consumed it before this went out -- and that is the shop car's
--- known fault in a much smaller window, which is stated here rather than
--- pretended away. Repairing whatever car they are in NOW would be the worse
--- answer: it spends a kit on a car nobody aimed it at.
---
--- `didHit`, not a bare read. IsPedInAnyVehicle is declared BOOL and `0` is
--- truthy in Lua; the FUEL_SET handler above reads it the same way.
RegisterNetEvent(BR.Net.VEH_FIX)
AddEventHandler(BR.Net.VEH_FIX, function(d)
    if type(d) ~= 'table' then return end
    local nid = math.tointeger(tonumber(d.n))
    if nid == nil then return end

    local points = tonumber(d.r) or 0.0
    if points <= 0.0 then return end

    local ped = PlayerPedId()
    if not didHit(IsPedInAnyVehicle(ped, false)) then return end
    local veh = GetVehiclePedIsIn(ped, false)
    if netOf(veh) ~= nid then return end

    applyRepair(veh, points)
end)

--- The pump cues, played from the car so everybody in it hears them.
---
--- ═══ WHY THIS IS A MESSAGE AND NOT A LOCAL DECISION ═══
---
---   "All occupants of a vehicle should hear these sounds."
---                                          -- owner, 2026-08-22
---
--- A passenger's client does not know the driver is holding a key, and cannot
--- be told by the driver's client -- there is no client-to-client channel and
--- there must not be one. The server is the only thing that knows both facts it
--- needs (who is holding, who is aboard) and it already knows them both for the
--- ledger, so it addresses the cue and this end just plays it.
---
--- PLAYED FROM THE ENTITY, so the engine positions and mixes it against
--- whatever else is happening. See BR.Sfx.playFrom for why the native cannot do
--- the networking itself.
---
--- THE CUE NAME IS AN INDEX, NOT A SOUND NAME. BR.Sfx.playFrom looks it up in
--- BR.Config.Audio.cues and ignores anything it does not recognise, so the worst
--- a malformed message can do is nothing.
RegisterNetEvent(BR.Net.FUEL_SFX)
AddEventHandler(BR.Net.FUEL_SFX, function(d)
    if type(d) ~= 'table' then return end
    local nid = math.tointeger(tonumber(d.n))
    if nid == nil or nid == 0 or type(d.c) ~= 'string' then return end

    -- RESOLVED FRESH RATHER THAN ASSUMED TO BE THE CAR WE ARE IN. The player
    -- may have left the seat in the milliseconds this message was in flight,
    -- and a cue that follows them out of the car would be wrong twice over.
    local ok, ent = pcall(NetworkGetEntityFromNetworkId, nid)
    -- `0` IS TRUTHY IN LUA and it is what this native answers for a network id
    -- that resolves to nothing here -- a car that has streamed out, or another
    -- match's. didHit() covers DoesEntityExist for the same reason.
    if not ok or not ent or ent == 0 or not didHit(DoesEntityExist(ent)) then
        return
    end

    if BR.Sfx and BR.Sfx.playFrom then BR.Sfx.playFrom(d.c, ent) end
end)

--- ═══ THE TWO ENGINE SWITCHES, SET ON EVERY RESOURCE START ═══
---
--- Both are GLOBAL rather than per-vehicle, and both are reset to their defaults
--- when a resource stops, so this cannot be a one-time call at boot -- it has to
--- run again every time br_core restarts or a `/refresh` bounces it.
---
--- Consumption ON is what gives a zero tank a stall at all; the multiplier at 0
--- is what stops the engine also draining the tank behind the server's back.
--- BR.Config.Fuel.consumptionState carries the full argument.
local function applyEngineSwitches()
    if not enabled() then return end
    if SetFuelConsumptionState then
        pcall(SetFuelConsumptionState, F.consumptionState == true)
    end
    if SetFuelConsumptionRateMultiplier then
        pcall(SetFuelConsumptionRateMultiplier,
              (tonumber(F.consumptionMultiplier) or 0.0) + 0.0)
    end
end

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    applyEngineSwitches()
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    hideBlips()
end)

--- Everything a fuel report needs, for `/brfuel`.
---
--- THE SAME NAME AS THE SERVER'S, which is this project's convention rather
--- than a collision: client and server are separate Lua states, tools/verify.sh
--- buckets its duplicate-command gate by side for exactly that reason, and
--- brloot / brparty / brvoice already exist on both.
---
--- IT PRINTS THE NATIVES AS WELL AS THE NUMBERS. Three of the four things this
--- file leans on -- the entry-animation handle, the handling float and the
--- closest-object search -- are natives this project had never used before, and
--- an unknown binding THROWS: five throws suspend the callback, and a suspended
--- callback is silent, which is this project's most expensive failure mode.
RegisterCommand('brfuel', function()
    local ped = PlayerPedId()
    print(('[br_core] fuel: %s, tank %s m, %d station(s), %d blip(s)')
        :format(enabled() and 'on' or 'OFF', tostring(F and F.tankMetres),
                F and #F.stations or 0, #blips))
    local veh = didHit(IsPedInAnyVehicle(ped, false))
        and GetVehiclePedIsIn(ped, false) or 0
    local nid = netOf(veh)
    print(('  in vehicle %s (netId %s)'):format(tostring(veh), tostring(nid)))
    if nid and known[nid] then
        print(('  ledger says %d m (%.3f of a tank)')
            :format(known[nid].m, known[nid].f))
    else
        print('  no ledger reading held for it')
    end
    -- THE DISTANCE AND THE RADIUS, SIDE BY SIDE. `promptRadius` is the one
    -- number in this feature that cannot be checked without a live server -- it
    -- is measured from the vehicle's origin, which is roughly the middle of the
    -- car, to the pump prop's -- so the next adjustment to it should be read off
    -- a parked car rather than reasoned about. `dist` is whatever the pump loop
    -- last measured, and is nil until the player parks at a station.
    print(('  station %s, pump prop %s at %s m (prompt draws within %s m)')
        :format(at.station and (at.station.id or 'yes') or 'none',
                tostring(at.pump),
                at.dist and ('%.1f'):format(at.dist) or '?',
                tostring(F and F.promptRadius)))
    -- THE SECOND MEASUREMENT, AND THE REASON IT IS HERE. `refuelRadius` is the
    -- server's own test and the one this client mirrors to decide whether to
    -- draw at all, and its safe value depends on how far real pumps sit from
    -- these authored forecourt centres -- which nobody has measured. Park at
    -- the awkward stations, read this line, and the next value is a measurement.
    print(('  station centre at %s m (refuel allowed within %s m)')
        :format(at.stationDist and ('%.1f'):format(at.stationDist) or '?',
                tostring(F and F.refuelRadius)))
    local n = 0
    for _ in pairs(known) do n = n + 1 end
    print(('  %d network id(s) remembered'):format(n))
end, false)
