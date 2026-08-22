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
--- `dist` is the last measured metres from the vehicle to that anchor. It is
--- kept for `/brfuel` and for nothing else: `promptRadius` is the one value in
--- this feature that cannot be checked outside a live server, and a debug line
--- that prints the live distance beside the radius is what makes the next
--- number measured rather than guessed.
local at = {
    station = nil, pump = nil, pumpAt = 0,
    px = nil, py = nil, pz = nil, dist = nil,
}

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
--- ALL THREE HEALTH POOLS, because "restored" with one of them left low is a car
--- that looks fine and dies to the next bump. Body is the panels, engine is
--- whether it runs, petrol tank is whether it catches fire.
---
--- THE DEFORMATION IS FIXED ONCE, AT THE TOP. Dents are visual and popping them
--- out a tenth at a time reads as the car breathing; doing it on the frame the
--- body reaches full reads as the repair finishing.
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

    bump(GetVehicleEngineHealth, SetVehicleEngineHealth)
    bump(GetVehiclePetrolTankHealth, SetVehiclePetrolTankHealth)
    local body = bump(GetVehicleBodyHealth, SetVehicleBodyHealth)
    if body >= cap and SetVehicleDeformationFixed then
        pcall(SetVehicleDeformationFixed, veh)
    end
end

-- ---------------------------------------------------------------------------
-- The two bars
-- ---------------------------------------------------------------------------

--- What the interface was last told, so an unchanged readout is not re-sent.
local lastBars = { show = nil, health = -1, fuel = -1 }

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
    local health, fuel = 0, 0
    if show then
        health = math.floor(healthPct(veh) + 0.5)
        -- AN UNKNOWN TANK READS FULL, NOT EMPTY. This is the gap between
        -- sitting down and the server's answer arriving, and a bar that flashed
        -- empty for a tenth of a second every time somebody got into a car
        -- would be read as the car being dry.
        fuel = math.floor(BR.FuelSolve.clamp(fuelFrac or 1.0, 1.0) * 100.0 + 0.5)
    end

    if show == lastBars.show and health == lastBars.health
       and fuel == lastBars.fuel then
        return
    end
    lastBars.show, lastBars.health, lastBars.fuel = show, health, fuel

    TriggerEvent('br:ui:sendLocal', BR.Nui.VEHICLE, {
        show = show, health = health, fuel = fuel,
    })
end

-- ---------------------------------------------------------------------------
-- Station blips
-- ---------------------------------------------------------------------------

--- Put every station on the map.
---
--- ═══ THE OWNER ASKED FOR ALL OF THEM, AND ONLY WHILE ABOARD ═══
---
---   "Also, while in a vehicle (any seat), all gas stations should be shown as
---    blips on the map."   -- owner, 2026-08-21, #195
---
--- ANY SEAT, so this is not gated on being the driver: a passenger navigating
--- for the driver is the case that makes the rule worth having.
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
local function resolvePump(x, y, z, now)
    if at.pump and (now - at.pumpAt) < (tonumber(F.pumpRefreshMs) or 3000) then
        return
    end
    at.pumpAt = now
    at.pump = nil

    local reach = tonumber(F.pumpSearchRadius) or 0.0
    if reach <= 0.0 or type(F.pumpModels) ~= 'table' then return end

    local bestD = math.huge
    for i = 1, #F.pumpModels do
        local ok, obj = pcall(GetClosestObjectOfType, x, y, z, reach,
                              F.pumpModels[i], false, false, false)
        if ok and obj and obj ~= 0 and didHit(DoesEntityExist(obj)) then
            local okc, c = pcall(GetEntityCoords, obj)
            if okc and c then
                local d = BR.Dist(x, y, c.x, c.y)
                if d < bestD then
                    bestD = d
                    at.pump = obj
                    at.px, at.py, at.pz = c.x, c.y, c.z
                end
            end
        end
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
--- @param show boolean
local function setPrompt(show)
    show = (show == true)
    if promptShown == show then return end
    promptShown = show

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    local key = BR.Keys and BR.Keys.labelFor and BR.Keys.labelFor('brinteract') or nil
    BR.Dui.send(page, {
        t = 'prompt', show = true,
        label = PROMPT_LABEL,
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
        at.station, at.pump, at.dist = nil, nil, nil
        return
    end

    -- ANY SEAT. The blips are the passenger's as much as the driver's.
    showBlips()

    local veh = GetVehiclePedIsIn(ped, false)
    local nid = netOf(veh)
    if nid == nil then
        -- A non-networked vehicle -- the Battle Bus, #191's ambulance. The
        -- server has never heard of it and it has no tank here, so the fuel bar
        -- would be describing nothing. The bars stay down rather than reading
        -- full forever.
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
        at.station, at.pump, at.dist = nil, nil, nil
        return
    end

    local okc, c = pcall(GetEntityCoords, veh)
    if not okc or c == nil then return end

    local station = BR.FuelSolve.stationNear(c.x, c.y, F.stations, F.stationRadius)
    if station == nil then
        setPrompt(false)
        at.station, at.pump, at.dist = nil, nil, nil
        return
    end

    local now = GetGameTimer()
    if at.station ~= station then
        at.station = station
        at.pump, at.pumpAt = nil, 0
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

    local inReach
    inReach, at.dist = BR.FuelSolve.atPump(c.x, c.y, px, py,
                                           tonumber(F.promptRadius) or 0.0)
    setPrompt(inReach)

    if inReach then
        local pz = (at.pz or (tonumber(station.z) or c.z))
                   + (tonumber(F.promptLift) or 1.4)
        BR.Dui.drawWorld(promptPage(), px, py, pz, tonumber(F.promptScale) or 1.6)
    end

    -- ═══ THE HOLD ═══
    --
    -- REFUELLING IS STILL THE STATION'S RADIUS, NOT THE PLATE'S. This send is
    -- deliberately outside the `inReach` branch above: the owner confirmed
    -- refuelling works and asked only for the plate to come closer, and the
    -- server re-derives eligibility from `stationRadius` anyway -- gating the
    -- send on a client-side pump distance would put a rule in front of the
    -- server's that the server does not have, for no reason the player asked
    -- for. The visible cost is the gap: between 3m and 30m of a station a hold
    -- fills the tank with nothing on screen saying so.
    --
    -- One message every `pumpSendMs` for as long as the key is down, and the
    -- server decides what each one is worth from the wall clock. Sending faster
    -- earns nothing (BR.FuelSolve.grantMs), which is why this cadence can be a
    -- comfort rather than a security boundary.
    local nid = netOf(veh)
    if nid == nil then return end
    if not (BR.Keys and BR.Keys.isHeld and BR.Keys.isHeld('interact')) then return end
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
    local n = 0
    for _ in pairs(known) do n = n + 1 end
    print(('  %d network id(s) remembered'):format(n))
end, false)
