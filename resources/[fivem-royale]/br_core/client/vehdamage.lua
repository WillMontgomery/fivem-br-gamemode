-- Making a car breakable: four floats, written on the machine that matters.
--
--   "the vehicle collision/cosmetic damage should be set way higher than it is
--    right now. As you may be aware, damaging vehicles to a point of total
--    failure is nearly impossible in base GTA V. That should not be the case
--    here."                                     -- owner, 2026-08-22, #213
--
-- Every number is in br_lib/config/vehicles.lua under BR.Config.VehicleDamage,
-- including which fields are written and what each one governs. This file is
-- the part that touches the engine, and it is deliberately the only part that
-- does. It writes NO health, opens NO channel, creates NO entity and has NO
-- server half.
--
-- ═══ WHY THE CLIENT, WHICH IS NOT A PREFERENCE ═══
--
-- SET_VEHICLE_HANDLING_FLOAT is a Cfx native declared `apiset: client`. There
-- is no server handler for it and there is no server-side equivalent -- the
-- same wall server/fuel.lua describes for the fuel level and config/vehicles.lua
-- describes for GetVehicleClass. So the choice was never "client or server";
-- it was "the client, or not at all".
--
-- ═══ WHO HAS TO HAVE APPLIED IT, AND WHAT HAPPENS WHEN OWNERSHIP MOVES ═══
--
-- The write is LOCAL. FiveM implements it by cloning the model's CHandlingData
-- onto that one entity on that one machine, so it changes what THIS client's
-- physics thinks about that car and nothing else. Which would be useless, were
-- it not for the two facts that make it work:
--
--   * THE OWNER RUNS THE PHYSICS. Collision damage is computed by whichever
--     client owns the entity, out of ITS copy of the handling. So the owner's
--     multipliers are the ones that decide what a crash costs.
--   * VEHICLE HEALTH IS NETWORKED. Body, engine and petrol-tank health ride the
--     vehicle's own sync tree, so the number the owner arrives at is the number
--     every other machine reads -- including the one drawing the condition bar
--     for a passenger. Nothing here has to be broadcast, because the RESULT
--     already is.
--
-- Ownership follows proximity and migrates on its own -- #193 §2 collects the
-- platform's documentation of that, and server/vehicles.lua's `ownerOf` note
-- says the same thing about peds. In practice the DRIVER owns the car they are
-- driving, which is exactly the case this feature is about.
--
-- SO EVERY CLIENT APPLIES IT TO THE CAR IT IS IN, INCLUDING PASSENGERS. A
-- passenger is a plausible next owner -- they are inside the entity, so they are
-- as close to it as anybody can be -- and applying it costs four native calls.
-- The driver is covered because the driver is in it; a migration to a passenger
-- is covered because the passenger already did it; a migration to the player
-- climbing in is covered because it is applied on the ENTRY ANIMATION, about a
-- second before the seat is taken (client/fuel.lua opens the same window for the
-- same reason, and this reuses its shape rather than inventing a second one).
--
-- WHAT IS NOT COVERED, STATED RATHER THAN GLOSSED: a car owned by a client who
-- is NOT in it and never has been -- an empty car near a player, or a car whose
-- ownership the engine handed to a bystander -- keeps GTA's own multipliers on
-- that machine. It matters least where it happens most: an unoccupied car
-- nobody is driving is not the permanent advantage #213 is about, and the
-- moment somebody gets in, the machine that owns it is a machine that applied.
-- Closing it entirely would mean walking every vehicle in scope every second,
-- which is hundreds of cars under BR.Config.Ambient for the sake of a parked
-- one's dents.
--
-- ═══ WHY OCCUPANCY IS THE ADMISSION, AND WHOSE IDEA IT IS ═══
--
-- It is server/fuel.lua's, exactly: "a vehicle enters this registry ONLY BY
-- BEING OCCUPIED BY A PLAYER, which bounds the live set by how many cars the
-- players in a match have actually used." The same rule bounds this one, and
-- for the same reason -- #193's Option A means the world is FULL of vehicles
-- this gamemode did not make, and a pass over all of them is not affordable on
-- any tick.
--
-- The mechanism could not be shared, and that is a property of the natives
-- rather than a decision. server/fuel.lua's ledger and server/vehicles.lua's
-- occupancy sampler both live on the server, and neither can call a client
-- native; so the RULE is reused and the READ is local -- `IsPedInAnyVehicle`
-- plus `GetVehiclePedIsIn`, which is the same pair client/fuel.lua's tick
-- already asks. No third notion of "occupied" is introduced anywhere.
--
-- ═══ THE BASELINE IS READ ONCE PER MODEL, AND THAT IS THE SUBTLE PART ═══
--
-- The write is `model's own value x multiplier`, so it needs the model's own
-- value -- and GET_VEHICLE_HANDLING_FLOAT returns the EFFECTIVE value, which is
-- our own write once we have made one. Reading it back and multiplying again
-- would compound, every tick, until a car dissolved on a kerb.
--
-- So the stock reading is taken ONCE PER MODEL and every write after that is
-- computed from it. Two Grangers have identical stock handling -- it is a
-- property of the model, not of the car -- so once is not an approximation, it
-- is the fact. And because every write is `baseline x multiplier` rather than
-- `current x multiplier`, writing it again changes nothing: the applier is
-- idempotent by construction, which is what lets it simply run every tick and
-- not care whether the car streamed out, changed hands, or was written by
-- something else.
--
-- THE ONE WAY IT CAN DRIFT, AND IT IS BOUNDED AND DEV-ONLY. If br_core restarts
-- while a car we already wrote to is still in the world, the cache is gone and
-- the next baseline read off that model sees OUR value as though it were stock.
-- Three things hold it: the resource puts the car it is in back to stock on its
-- way out (below), the result is clamped at BR.Config.VehicleDamage.ceiling so
-- the worst case saturates at GTA's documented top of range rather than running
-- away, and /brvehdamage prints the baseline it is using so it can be seen. It
-- needs a `/refresh` mid-drive to happen at all.
--
-- ═══ WHAT THIS DOES TO THE CONDITION BAR ═══
--
-- Nothing directly, and a great deal in practice. client/fuel.lua's healthPct
-- reads the WORST of body, engine and petrol-tank health and the HUD draws it
-- captioned and numeric. This file changes none of those three; it changes how
-- fast two of them fall. So the bar keeps meaning exactly what it meant and
-- starts moving -- a bar that used to sit at 100 for most of a match now drops
-- on impacts, reaches zero, and is a warning rather than an ornament. A stop at
-- a station puts all three back and the bar with them, which is the fuel work's
-- and not this file's.
--
-- ═══ AND WHAT IT DOES TO #194 ═══
--
-- More cars will explode with nobody to credit, and that is the settled answer
-- rather than a regression: "It's by design that vehicles in the game can
-- explode under normal circumstances, without a killer necessarily." Nothing
-- here attributes anything. server/damage.lua's explosion ledger already
-- declines a vehicle blast by type ("a car, a petrol pump: nobody's kill"), and
-- server/vehicles.lua's roadkill ledger will not take a crash -- see the guard
-- there that keeps two people in one cabin out of each other's kill feed.

BR = BR or {}
BR.VehDamage = {}

local C = BR.Config and BR.Config.VehicleDamage

--- A FiveM BOOL is not a Lua boolean.
---
--- A native declared BOOL hands Lua a number on some builds and a boolean on
--- others, and IN LUA `0` IS TRUTHY -- `1 == true` is also false. This project
--- has shipped that bug four times. `IsPedInAnyVehicle` is declared BOOL and is
--- the gate on everything below: a `0` read as true would send this file
--- looking for the handling of a vehicle a player on foot is not in.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v == 1 or v == true
end

--- Is the feature switched on and pointed the right way?
---
--- A MULTIPLIER AT OR BELOW ZERO SWITCHES IT OFF RATHER THAN MAKING CARS
--- INVULNERABLE. Zero is a valid handling value meaning "immune to damage", so
--- a config typo of 0 would produce the exact opposite of this feature -- and it
--- would look like the feature simply not working, which is the failure mode
--- nobody debugs. The same shape as client/fuel.lua's `enabled`, which requires
--- a positive tank for the same class of reason.
--- @return boolean
local function enabled()
    if C == nil or C.enabled ~= true then return false end
    if type(C.fields) ~= 'table' or #C.fields == 0 then return false end
    return (tonumber(C.multiplier) or 0) > 0
end

--- Stock handling per MODEL. [model] = { [fieldName] = number }
local stock = {}
local stockCount = 0

--- The last vehicle written to, so the resource can put it back on the way out.
local last = { veh = 0, model = nil }

local stat = {
    models = 0, applied = 0, refused = 0, clamped = 0, restored = 0,
}

--- Everything `/brvehdamage` and the suite read. Never written from outside.
--- @return table
function BR.VehDamage.stats()
    return {
        enabled  = enabled(),
        models   = stockCount,
        applied  = stat.applied,  refused  = stat.refused,
        clamped  = stat.clamped,  restored = stat.restored,
        veh      = last.veh,      model    = last.model,
    }
end

--- The stock reading held for a model, or nil. For the report and the suite.
--- @param model integer|nil
--- @return table|nil
function BR.VehDamage.baselineFor(model)
    if model == nil then return nil end
    return stock[BR.NormHash(model)]
end

--- Forget every baseline. Exposed for the suite; nothing in the game calls it.
function BR.VehDamage.reset()
    stock, stockCount = {}, 0
    last = { veh = 0, model = nil }
    for k in pairs(stat) do stat[k] = 0 end
end

--- Which model this handle is, normalised, or nil.
---
--- NORMALISED FOR BR.NormHash's OWN REASON -- the engine reports model hashes
--- signed and this is a table key, so an unnormalised one would key the same
--- model two different ways depending on which side of the wire named it.
---
--- ZERO IS REJECTED EXPLICITLY, AND `0` IS TRUTHY IN LUA. It is what the engine
--- answers for a handle that has gone bad, and a baseline stored under 0 would
--- be one row shared by every vehicle nobody could name -- so the first bad read
--- would decide the handling of the next unrelated car.
--- @param veh integer
--- @return integer|nil
local function modelOf(veh)
    local ok, m = pcall(GetEntityModel, veh)
    if not ok then return nil end
    m = BR.NormHash(m)
    if m == nil or m == 0 then return nil end
    return m
end

--- Read a model's own multipliers off one of its instances.
---
--- pcall'd, AND NOT DEFENSIVELY. citizenfx/fivem#1754 is
--- SetVehicleHandlingFloat raising "Error executing native ... at address
--- handling-loader-five.dll" on a perfectly ordinary
--- `(veh, 'CHandlingData', 'fEngineDamageMult', 1.0)` -- closed with no
--- documented fix. An uncaught throw inside a loop callback costs five of them
--- before BR.Loop suspends the callback entirely, silently, which is this
--- project's most expensive failure mode.
---
--- ALL OR NOTHING. One unreadable field refuses the whole model rather than
--- storing a partial baseline: a partial one would scale two multipliers and
--- leave the third at stock, which is a car that dents but will not die and
--- reads exactly like the bug this feature exists to fix.
--- @param veh integer
--- @return table|nil
local function readStock(veh)
    local out = {}
    for i = 1, #C.fields do
        local f = C.fields[i]
        local ok, v = pcall(GetVehicleHandlingFloat, veh, C.class, f.field)
        v = ok and tonumber(v) or nil
        -- `v ~= v` IS THE NaN TEST. A NaN baseline poisons every write derived
        -- from it, for that model, for the rest of the session.
        if v == nil or v ~= v then return nil end
        out[f.field] = v
    end
    return out
end

--- Put this gamemode's multipliers on one vehicle.
---
--- IDEMPOTENT BY CONSTRUCTION -- see the header. Every write is derived from the
--- model's stored baseline and never from what the field currently holds, so
--- calling this a hundred times is calling it once.
--- @param veh integer|nil
--- @return boolean applied
local function applyTo(veh)
    if not veh or veh == 0 then return false end

    local model = modelOf(veh)
    if model == nil then stat.refused = stat.refused + 1 return false end

    local base = stock[model]
    if base == nil then
        -- PAST THE CAP A NEW MODEL KEEPS STOCK HANDLING. The fail-safe
        -- direction: a car that is harder to break than intended, never one
        -- whose multipliers came from somewhere unexamined.
        if stockCount >= (math.tointeger(tonumber(C.maxModels)) or 0) then
            stat.refused = stat.refused + 1
            return false
        end
        base = readStock(veh)
        if base == nil then stat.refused = stat.refused + 1 return false end
        stock[model] = base
        stockCount = stockCount + 1
        stat.models = stockCount
    end

    for i = 1, #C.fields do
        local f = C.fields[i]
        local want, clamped =
            BR.Config.VehicleDamage.scale(base[f.field], C[f.from], C.ceiling)
        if want ~= nil then
            -- `+ 0.0` FORCES A FLOAT. Lua 5.4 has integers, the native wants a
            -- float, and an integer 5 arriving where a float is expected is the
            -- kind of argument-marshalling mismatch #1754 above looks like.
            pcall(SetVehicleHandlingFloat, veh, C.class, f.field, want + 0.0)
            if clamped then stat.clamped = stat.clamped + 1 end
        end
    end

    last.veh, last.model = veh, model
    stat.applied = stat.applied + 1
    return true
end

--- Put one vehicle back to the handling GTA gave it.
---
--- ═══ WHY THE RESOURCE BOTHERS ON ITS WAY OUT ═══
---
--- The write outlives this resource -- it is on the entity, not on us -- and the
--- baseline cache does not. So a `/refresh` with a modified car under the player
--- would leave the next start reading our own value as though it were stock. The
--- same shape as client/boost.lua's flames, which "outlive the resource that
--- started" them and are put out for exactly that reason.
---
--- BEST EFFORT AND ONE CAR. It is the car the player is sitting in, which is the
--- one the next start would immediately re-baseline from. A car parked down the
--- road keeps our multipliers until it streams out, and the ceiling is what
--- bounds that -- see the header.
--- @param veh integer|nil
--- @param model integer|nil
local function restore(veh, model)
    if not veh or veh == 0 or model == nil then return end
    local base = stock[model]
    if base == nil then return end
    for i = 1, #C.fields do
        local f = C.fields[i]
        local v = base[f.field]
        if v ~= nil then
            pcall(SetVehicleHandlingFloat, veh, C.class, f.field, v + 0.0)
        end
    end
    stat.restored = stat.restored + 1
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------

--- Keep the car under this player breakable.
---
--- ═══ TICK, AND THE RATE BUYS THE REASSERTION RATHER THAN THE WRITE ═══
---
--- The handling does not change ten times a second; the write is the same four
--- floats every pass. What the rate buys is that no transition has to be
--- enumerated -- and two of those transitions genuinely erase the override
--- rather than merely risking it:
---
---   STREAMING. The clone is taken from the model's template when the CVehicle
---              is constructed. A car that streams out and back in has been
---              constructed again, so it is holding template values and our
---              write is silently gone.
---   OWNERSHIP. The new owner's copy is its own clone of the template. Nothing
---              carries the override across the migration, because the override
---              is not in any sync node -- so re-applying is required rather
---              than defensive.
---
--- Both are corrected within 100ms and neither has to be detected. client/fuel
--- .lua's `fuel.apply` makes the same trade in the same band and costs the same
--- two natives to find the vehicle, so this adds four writes to a pass that was
--- already being taken.
---
--- THE IDLE PATH IS ONE NATIVE. A player on foot -- which is most players most
--- of the time -- reaches `IsPedInAnyVehicle`, reads false, and leaves.
BR.Loop.register(BR.Loop.TICK, 'vehdamage.apply', function()
    if not enabled() then return end

    local ped = PlayerPedId()

    -- THE CAR THEY ARE CLIMBING INTO, BEFORE THE SEAT IS TAKEN. The entry
    -- animation runs for about a second, and ownership arrives with the seat --
    -- so applying here means the multipliers are already on the car at the
    -- instant this machine becomes the one whose physics decide what a crash
    -- costs. client/fuel.lua opens this window for the stall; this rides it.
    local entering = GetVehiclePedIsEntering and GetVehiclePedIsEntering(ped) or 0
    if entering and entering ~= 0 then applyTo(entering) end

    -- ANY SEAT. A passenger is a plausible next owner and applying costs four
    -- writes; a passenger who is not asked would be a car that briefly reverts
    -- to stock handling the moment the driver gets out. See the header.
    if not isTrue(IsPedInAnyVehicle(ped, false)) then
        last.veh, last.model = 0, nil
        return
    end

    local veh = GetVehiclePedIsIn(ped, false) or 0
    -- ZERO IS EXPLICIT AND `0` IS TRUTHY. `if veh then` is true for a player the
    -- engine could not put in a car.
    if veh == 0 then
        last.veh, last.model = 0, nil
        return
    end

    applyTo(veh)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle and the readout
-- ---------------------------------------------------------------------------

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    restore(last.veh, last.model)
end)

--- What this client is actually doing to the car it is in.
---
--- ═══ THE ONE THING THAT CANNOT BE SETTLED WITHOUT A LIVE SERVER PRINTS ITSELF
---     ═══
---
--- How hard a car should be to destroy is a playtest question, and the only way
--- to turn `multiplier` from a guess into a measurement is to be able to read
--- what it produced on a real vehicle. So this prints the model's stock value,
--- what we wrote, and what the engine says the field holds NOW -- three numbers
--- that should be `s`, `s x multiplier`, and the second one again. Any
--- disagreement between the last two is the native having refused the write,
--- which is citizenfx/fivem#1754's symptom and is otherwise completely silent.
---
--- IT ALSO PRINTS THE NATIVES. Both handling natives are ones this project had
--- never used before #213, and an unknown binding THROWS -- five throws suspend
--- the callback, and a suspended callback says nothing at all.
RegisterCommand('brvehdamage', function()
    local s = BR.VehDamage.stats()
    print(('[br_core] vehicle damage: %s   x%s   ceiling %s')
        :format(s.enabled and 'on' or 'OFF',
                tostring(C and C.multiplier), tostring(C and C.ceiling)))
    print(('  natives: getHandling=%s setHandling=%s')
        :format(tostring(type(GetVehicleHandlingFloat) == 'function'),
                tostring(type(SetVehicleHandlingFloat) == 'function')))
    print(('  %d model baseline(s) held   applied %d  refused %d  clamped %d  restored %d')
        :format(s.models, s.applied, s.refused, s.clamped, s.restored))

    local ped = PlayerPedId()
    local veh = isTrue(IsPedInAnyVehicle(ped, false))
        and (GetVehiclePedIsIn(ped, false) or 0) or 0
    if veh == 0 then
        print('  not in a vehicle -- nothing to read')
        return
    end

    local model = modelOf(veh)
    local base  = model and stock[model] or nil
    print(('  vehicle %s  model %s  baseline %s')
        :format(tostring(veh), model and ('0x%08X'):format(model) or '?',
                base and 'held' or 'NOT HELD'))
    if not base or not C then return end

    for i = 1, #C.fields do
        local f = C.fields[i]
        local want = BR.Config.VehicleDamage.scale(base[f.field], C[f.from], C.ceiling)
        local ok, now = pcall(GetVehicleHandlingFloat, veh, C.class, f.field)
        print(('    %-24s stock %-8.3f wrote %-8s engine says %-8s  (%s)')
            :format(f.field, base[f.field],
                    want and ('%.3f'):format(want) or '-',
                    ok and ('%.3f'):format(tonumber(now) or 0.0) or 'REFUSED',
                    f.governs))
    end
end, false)
