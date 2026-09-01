-- The warmup vehicle shop, client side (#224): the showroom, the plate, the
-- keypress, and the car that comes out of the item.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- "THE VEHICLE WHICH SPAWNS FROM THEIR INVENTORY MUST BE EXACTLY AS SHOWN WHEN
--  THEY PURCHASED IT" -- owner, 2026-08-29
-- ═══════════════════════════════════════════════════════════════════════════
--
-- BR.Shop.dress IS THAT PROMISE, AND IT IS THE ONLY WAY EITHER CAR IS EVER
-- DRESSED. The showroom vehicle on the warmup pad and the vehicle a player
-- unpacks forty minutes later are both built by that one function, from
-- BR.ShopSolve.appearance over one authored config row. They are not "kept in
-- sync" -- there is nothing to keep in sync. They are the same computation run
-- twice.
--
-- THE ALTERNATIVE WAS REJECTED DELIBERATELY. Reading the appearance off the
-- display entity at purchase time and replaying it later would work, and it
-- would create a SECOND REPRESENTATION of one fact: the authored row, and a
-- recording taken from an entity built out of it. That is this repository's
-- signature defect and it has shipped several times. It is also untestable from
-- outside a running client, where this is a pure function over a table that
-- tools/test_shop.lua exercises directly.
--
-- ═══ THE COLOURS ARE ROLLED, AND THE ROW GAINED A SECOND INPUT RATHER THAN A
--     SECOND REPRESENTATION (owner, 2026-08-31) ═══
--
-- "can you make the vehicles in the shop spawn with random colors each time
--  they are spawned? except the ambulance."
--
-- BR.Shop.dress now takes a SEED as well as a row, and BR.ShopSolve.appearance
-- derives the paint from the pair. The seed is the SERVER'S -- one per match,
-- rolled once, asked for by the reconciler below and re-sent with the delivery
-- -- so this file never invents a colour, never remembers one, and never tells
-- the server what it painted. It receives a number and derives.
--
-- WHICH IS WHY THERE IS STILL NOTHING TO KEEP IN SYNC. The showroom car and the
-- bought car are dressed from one row and one seed; a rebuild mid-warmup asks
-- for the same seed and repaints the pad identically, so a car cannot change
-- colour under a player who is reading its price.
--
-- NOTHING ABOUT AN APPEARANCE EVER CROSSES THE WIRE. The purchase carries a
-- catalogue id, the inventory item carries an item id, and the delivery message
-- carries a net id, a catalogue id and that one integer. Every client already
-- holds config/shop.lua, because config/ is a shared_script -- so the car is
-- reconstructed rather than transmitted, and the gap between warmup and the
-- moment somebody uses the item carries no state that could be lost or edited.
--
-- ═══ WHY THE SHOWROOM CARS ARE LOCAL AND THE BOUGHT CAR IS NOT ═══
--
-- The showroom is scenery: frozen, invincible, locked, un-enterable, and
-- identical on every machine because every machine builds it from the same
-- table. So each client makes its own with a NON-NETWORKED CreateVehicle -- the
-- same call and the same flags client/bus.lua uses for the Battle Bus. That
-- sidesteps `sv_entityLockdown relaxed` entirely (lockdown validates CLONES; a
-- local entity is never one), sidesteps citizenfx/fivem#2623 (the server never
-- made them, so they cannot be randomly deleted), and sidesteps the ownership
-- race that cost client/rescue.lua two playtest rounds.
--
-- The car a player PAID for is the opposite case and gets the opposite
-- treatment: other people have to be able to see it, steal it and shoot it, so
-- it is server-created through BR.Vehicles.spawnOwned and dressed here after
-- this machine has taken control of it.

BR = BR or {}
BR.Shop = BR.Shop or {}

local S = BR.Config.Shop

--- 0 IS TRUTHY IN LUA AND A FIVEM BOOL NATIVE MAY ANSWER 1 OR 0. Nine shipped
--- instances on this project; every client file carries this line.
local function isTrue(v) return v == true or v == 1 end

--- Call a native only if this build has it, and never let it throw.
---
--- THE APPEARANCE PASS IS ONE LONG RUN OF WRITES and a single missing native in
--- the middle of it would leave a half-dressed car -- which is the exact failure
--- "exactly as shown" cannot have. Guarding each write means a build without
--- (say) the dashboard-colour native produces a car missing that one detail on
--- BOTH cars alike, rather than a showroom car and a bought car that differ.
--- @param f any
local function nat(f, ...)
    if type(f) ~= 'function' then return end
    pcall(f, ...)
end

--- The usable catalogue on this client. Same rows the server resolved, from the
--- same config and the same refusal check.
local rows = {}

--- The showroom, by catalogue id: [id] = entity handle.
local cars = {}

--- What each car MEASURED at when it was built, by catalogue id.
---
--- A LEDGER, NOT A PLAN. Nothing in this file reads it to decide where anything
--- goes -- /brshop prints it and that is its whole purpose. It exists because
--- "the cars are floating" and "the cars moved after they were placed" are two
--- different reports and there has never been a before-reading to tell them
--- apart: the height a car settles to is gone the frame after it happens.
---
---   [id] = { settled = boolean,  -- did SET_VEHICLE_ON_GROUND_PROPERLY say yes
---            startZ  = number,   -- where CreateVehicle was told to put it
---            z       = number,   -- where it actually was once the settle ran
---            at      = number,   -- GetGameTimer at that moment
---            collAtBuild = boolean, -- HasCollisionLoadedAroundEntity, THEN
---            waitAtBuild = boolean, -- IsEntityWaitingForWorldCollision, THEN
---            waitedMs    = number } -- ms this car spent waiting for it
---
--- THE LAST THREE ARE SAMPLED AT THE BUILD AND NOWHERE ELSE, and that is the
--- entire reason they are written down. /brshop's `coll` and `wait` columns ask
--- those same two natives AT THE MOMENT THE COMMAND IS TYPED -- minutes after
--- the pad went up, with the player standing in the middle of it -- so a car
--- that was built into an empty world reads `coll Y` by the time anybody looks.
--- Reading those two columns as if they described the build is what sent this
--- bug's first diagnosis to the wrong place.
local placed = {}

--- Is the showroom standing?
local built = false

--- The match's paint seed, as the SERVER last stated it. nil until it answers.
---
--- ═══ THE PAD IS NOT BUILT WITHOUT ONE, AND THAT IS DELIBERATE ═══
---
--- Building on the authored colours while the answer is in flight would put a
--- showroom up in thirteen colours and then repaint it a second later -- and
--- worse, a player quick enough to press in that second would be looking at one
--- car and buying another. A pad that appears a beat late is a pad; a pad that
--- changes colour under somebody is the bug this whole file exists to not have.
---
--- CLEARED BY teardown, so leaving warmup forgets it and the next one is asked
--- for fresh. A seed that outlived its match would paint the next showroom in
--- the last one's colours.
local seed = nil

--- Building is asynchronous (models stream), so a state flap can start a second
--- build while the first is still waiting. Same generation token client/bus.lua
--- uses, and for the same reason: one flight produced two planes.
local gen = 0

--- Has this player already bought their car this match? Closes the shop on this
--- side the moment the server says yes, so the plate stops being offered.
---
--- ADVISORY ONLY. The server re-decides every purchase; this exists so a player
--- who has spent their allowance is not shown a price they cannot act on.
local spent = false

--- What the plate was last told, so it is sent on CHANGE rather than per frame.
local promptShown = false

--- The row the TICK pass decided to offer, held for the FRAME pass to draw
--- against -- and the ONE row a keypress may act on.
---
--- #128'S LESSON, APPLIED BEFORE IT COSTS ANYTHING. In client/loot.lua the
--- prompt and the claim used to resolve independently, and with two crates in
--- reach a player pressed while looking at one and took the other. Two cars on a
--- showroom floor is the same picture, which is why server/shop.lua warns at
--- load when two rows are closer together than the reach radius.
local candidate = nil

--- Model dimensions, cached by model hash. A model's size never changes and the
--- plate's position is read from it every frame.
local DIMS = {}

-- ---------------------------------------------------------------------------
-- The appearance
-- ---------------------------------------------------------------------------

--- Dress a vehicle exactly as one catalogue row describes.
---
--- THE ONE FUNCTION. Called for every showroom car when the pad is built, and
--- for the bought car when it arrives. Nothing else in this project writes a
--- shop car's appearance.
---
--- IDEMPOTENT AND ORDER-STABLE. Every field is written on every call, including
--- the ones the owner left blank -- BR.ShopSolve.appearance fills those with the
--- engine's own "leave it" sentinels. A dresser that skipped absent fields would
--- leave a freshly created vehicle wearing the RANDOM COLOUR the engine gives
--- it, which is drift with extra steps.
---
--- SetVehicleModKit FIRST. Every SetVehicleMod on a vehicle whose mod kit has
--- not been selected is a write to nothing; client/rescue.lua's ambulance does
--- the same thing in the same order.
---
--- ═══ THE SEED IS AN ARGUMENT, NOT A FILE-LEVEL READ, AND THAT IS THE POINT
---     ═══
---
--- It would be one character shorter to read the `seed` local above. Both
--- callers would then be reading a value that is nil for the whole of a match
--- -- the pad is torn down at wheels-up and `seed` goes with it -- so the car a
--- player unpacks forty minutes later would come out in its authored colour
--- while the showroom car came out rolled. Passing it in is what forces the
--- delivery to carry its own, from the server, which is the only copy that is
--- still alive by then.
--- @param veh integer
--- @param row table
--- @param paintSeed integer|nil  the match's seed; nil is the authored colour
function BR.Shop.dress(veh, row, paintSeed)
    if not veh or veh == 0 or not isTrue(DoesEntityExist(veh)) then return end
    local a = BR.ShopSolve.appearance(row, paintSeed, S.palette)

    nat(SetVehicleModKit, veh, 0)

    if a.primary >= 0 or a.secondary >= 0 then
        -- READ-THEN-WRITE so one authored colour does not blank the other. The
        -- native takes both, and a -1 for "leave it" is not something it
        -- understands.
        local okc, p, s = pcall(GetVehicleColours, veh)
        local pri = (a.primary   >= 0) and a.primary   or (okc and p or 0)
        local sec = (a.secondary >= 0) and a.secondary or (okc and s or 0)
        nat(SetVehicleColours, veh, pri, sec)
    end
    if a.pearl >= 0 or a.wheelColour >= 0 then
        local oke, pe, wh = pcall(GetVehicleExtraColours, veh)
        local pearl = (a.pearl       >= 0) and a.pearl       or (oke and pe or 0)
        local wheel = (a.wheelColour >= 0) and a.wheelColour or (oke and wh or 0)
        nat(SetVehicleExtraColours, veh, pearl, wheel)
    end

    if a.interior  >= 0 then nat(SetVehicleInteriorColour,  veh, a.interior)  end
    if a.dashboard >= 0 then nat(SetVehicleDashboardColour, veh, a.dashboard) end

    -- WHEEL TYPE BEFORE WHEELS. Slot 23 indexes into whatever wheel type is
    -- selected, so setting the type afterwards silently reassigns the wheel.
    if a.wheelType >= 0 then nat(SetVehicleWheelType, veh, a.wheelType) end

    if a.livery     >= 0 then nat(SetVehicleLivery,     veh, a.livery)     end
    if a.roofLivery >= 0 then nat(SetVehicleRoofLivery, veh, a.roofLivery) end
    if a.windowTint >= 0 then nat(SetVehicleWindowTint, veh, a.windowTint) end

    nat(SetVehicleDirtLevel, veh, a.dirt + 0.0)

    if a.plate then nat(SetVehicleNumberPlateText, veh, a.plate) end
    if a.plateIndex >= 0 then
        nat(SetVehicleNumberPlateTextIndex, veh, a.plateIndex)
    end

    -- ITERATED IN SLOT ORDER RATHER THAN IN pairs ORDER. Lua's pairs is
    -- unordered, and some mod slots depend on others having been written first
    -- (the wheel type above is the loud example). A stable order means two runs
    -- of this function over one row produce the same car, which is the whole
    -- point of it existing.
    local slots = {}
    for slot in pairs(a.mods) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
        nat(SetVehicleMod, veh, slot, a.mods[slot], false)
    end

    local toggles = {}
    for slot in pairs(a.toggles) do toggles[#toggles + 1] = slot end
    table.sort(toggles)
    for _, slot in ipairs(toggles) do
        nat(ToggleVehicleMod, veh, slot, a.toggles[slot])
    end

    if a.xenon then
        nat(ToggleVehicleMod, veh, 22, true)
        if a.xenonColour >= 0 then
            nat(SetVehicleXenonLightsColour, veh, a.xenonColour)
        end
    end

    -- EXTRAS ARE INVERTED AND THE INVERSION LIVES HERE, ONCE. SET_VEHICLE_EXTRA
    -- takes `true` to mean DISABLED -- client/rescue.lua carries the same note
    -- beside the same native ("false = ON"). The config reads the way a person
    -- would expect (`true` is on) and this is the only line that knows.
    local extras = {}
    for id in pairs(a.extras) do extras[#extras + 1] = id end
    table.sort(extras)
    for _, id in ipairs(extras) do
        nat(SetVehicleExtra, veh, id, not a.extras[id])
    end
end

-- ---------------------------------------------------------------------------
-- The showroom
-- ---------------------------------------------------------------------------

--- Take the showroom down. Safe to call twice and safe to call on a pad that
--- was never finished being built.
local function teardown()
    built = false
    gen = gen + 1            -- abandons any build still streaming models
    promptShown = false
    candidate = nil
    -- THE SEED BELONGS TO THE SHOWROOM IT PAINTED. Keeping it across a teardown
    -- would build the next match's pad in this match's colours, and the server's
    -- answer for that match would then disagree with what a player is standing
    -- in front of.
    seed = nil
    for id, veh in pairs(cars) do
        if veh and veh ~= 0 and isTrue(DoesEntityExist(veh)) then
            DeleteEntity(veh)
        end
        cars[id] = nil
        -- The ledger goes with the car it describes. A build reading left
        -- standing over a pad that has been taken down is a reading of a
        -- previous match, and /brshop would print it as if it were this one.
        placed[id] = nil
    end
end

--- Wait for the ground under one showroom car to arrive.
---
--- ═══ THE PAD IS BUILT FROM 1.36km AWAY, AND THAT IS THE WHOLE BUG ═══
---
--- Owner, 2026-08-31: "the positioning bug where vehicles are floating in the
--- shop -- that's still happening when going between buckets like `playing` to
--- `warmup` [...] this will happen to players if they come back to warmup after
--- a previous match."
---
--- THE SHOWROOM IS BUILT OFF THE STATE FLIP, NOT OFF ARRIVAL AT THE PAD. The
--- reconciler sees WARMUP and builds; at that moment the player is still in the
--- lobby, a kilometre and a third from the airfield, and there is no collision
--- resident under any of the thirteen rows. SET_VEHICLE_ON_GROUND_PROPERLY has
--- to have ground to put wheels on -- with none it answers false, and the code
--- below then freezes the car at a guessed height anyway. Until this function
--- existed NOTHING here ever waited for that ground, so whether a car landed
--- correctly was a RACE AGAINST STREAMING that the player's distance decided:
--- the owner's readouts show `settled at build 12/13` on a cold first build and
--- 0/13 on a rebuild.
---
--- SAME SHAPE AS client/loot.lua's awaitCollision, DELIBERATELY. That function
--- has solved this exact problem for loot crates since 835254d -- freeze,
--- RequestCollisionAtCoord, poll, give up on a budget -- and a second pattern
--- for one fault is a second thing that has to be kept right.
---
--- FROZEN WHILE IT WAITS AND UNFROZEN BEFORE IT RETURNS. This is the only thing
--- in the build that YIELDS, so it is the only point at which a newly created
--- car gets a simulation step -- and a car handed to the physics over ground
--- that has not arrived falls through the map, which would be a worse bug than
--- the one being fixed. THE UNFREEZE IS NOT OPTIONAL: a frozen entity does not
--- move, so the settle would pin it at the height it was floating at and report
--- success, which is the failure this file already warns about twice.
---
--- BOTH NATIVES ARE DECLARED BOOL AND 0 IS TRUTHY IN LUA. Read raw, this loop
--- either never waits at all or never stops -- the two spellings are wrong in
--- opposite directions, which is why both go through isTrue.
--- @param veh integer
--- @param row table
--- @param mine integer  the build generation this car belongs to
--- @return boolean loaded
--- @return number waited  milliseconds spent
local function awaitCollision(veh, row, mine)
    nat(FreezeEntityPosition, veh, true)
    nat(RequestCollisionAtCoord, row.x + 0.0, row.y + 0.0, row.z + 0.0)

    local budget = tonumber(S.collisionWaitMs) or 1500
    local waited = 0

    --- Released on EVERY exit, including the early ones. A hold that is only
    --- let go on the happy path is a showroom of cars frozen in mid-air.
    local function done(loaded)
        nat(FreezeEntityPosition, veh, false)
        return loaded, waited
    end

    while not isTrue(HasCollisionLoadedAroundEntity(veh))
            or isTrue(IsEntityWaitingForWorldCollision(veh)) do
        -- WHEN THE BUDGET RUNS OUT, TODAY'S BEHAVIOUR IS WHAT HAPPENS. A car
        -- placed the way it was placed before this existed beats a showroom
        -- that never finishes because one streaming request never completed.
        if waited >= budget then return done(false) end
        Citizen.Wait(50)
        waited = waited + 50
        -- THE ABANDONMENT CHECK BELONGS IN HERE. A state flap starts a second
        -- build, and a wait that outlives its own generation is a car nobody
        -- is going to put in `cars` and nobody is going to delete.
        if mine ~= gen then return done(false) end
        if not isTrue(DoesEntityExist(veh)) then return done(false) end
        nat(RequestCollisionAtCoord, row.x + 0.0, row.y + 0.0, row.z + 0.0)
    end
    return done(true)
end

--- Put the cars on the pad.
---
--- ONE THREAD FOR THE WHOLE SHOWROOM, not one per car: model streaming yields,
--- and a burst of RequestModel in one frame is how a dense scene turns into a
--- stutter (client/loot.lua's drain makes the same trade).
--- @param paintSeed integer the seed every car on this pad is painted from
local function build(paintSeed)
    if built then return end
    built = true
    gen = gen + 1
    local mine = gen

    Citizen.CreateThread(function()
        for _, row in ipairs(rows) do
            if mine ~= gen then return end

            local model = GetHashKey(row.model)
            if isTrue(IsModelValid(model)) and isTrue(IsModelAVehicle(model)) then
                RequestModel(model)
                local waited = 0
                while not isTrue(HasModelLoaded(model)) and waited < 5000 do
                    Citizen.Wait(50)
                    waited = waited + 50
                end
                if mine ~= gen then return end

                if isTrue(HasModelLoaded(model)) then
                    -- ═══ THE STARTING HEIGHT, WHICH IS HIS SURVEYED z LESS A
                    --     TUNABLE DROP (#243) ═══
                    --
                    -- Owner, 2026-08-30: "After seeing the shop once in warmup,
                    -- and going outside its focus area (cell/culling radius),
                    -- then coming back, all the vehicles are floating off the
                    -- ground again at waist level." And: "the same is true for
                    -- the vehicles. That's all we need."
                    --
                    -- HIS COORDINATES ARE NOT EDITED. "those coords are very
                    -- specifically placed. Don't change them" -- the row is
                    -- untouched and this is applied on top of it, at the
                    -- create and nowhere else.
                    --
                    -- IT LOSES TO THE GROUNDING BELOW, DELIBERATELY. When
                    -- SetVehicleOnGroundProperly succeeds it puts the wheels on
                    -- the surface and where the car started stops mattering, so
                    -- on a first spawn this is very likely invisible -- which is
                    -- the correct outcome and not a defect. A drop applied AFTER
                    -- a successful grounding would bury every car half a metre
                    -- into the pad.
                    --
                    -- AND SINCE THE FALLBACK BELOW STOPPED READING IT, IT IS A
                    -- NO-OP ON EVERY PATH -- which is exactly what the comment
                    -- above it always claimed it would be. A settled car is put
                    -- where the engine says; an unsettled one is put at the raw
                    -- survey. Both overwrite this height. It is left at 0.5
                    -- rather than deleted because it is the dial he named and
                    -- the one thing a spawn height still decides is how far a
                    -- car may fall in the frame before it is frozen.
                    local startZ = row.z + 0.0 - (tonumber(S.groundDropM) or 0.0)

                    -- LOCAL. NEVER NETWORKED. See the header, and client/bus.lua
                    -- for the same two `false`s in the same positions.
                    local veh = CreateVehicle(model, row.x + 0.0, row.y + 0.0,
                                              startZ,
                                              tonumber(row.heading) or 0.0,
                                              false, false)
                    SetModelAsNoLongerNeeded(model)

                    -- A HANDLE, AND 0 IS TRUTHY. `if veh then` reports a car
                    -- that does not exist; CreateVehicle answering 0 was the
                    -- eighth instance of this defect on this project and it cost
                    -- a full playtest round.
                    if veh and veh ~= 0 and isTrue(DoesEntityExist(veh)) then
                        -- THE OWNER'S THREE WORDS, IN ORDER: "doors locked,
                        -- invincible, and position frozen when at the store".
                        --
                        -- 2 is eVehicleLockState LOCKED -- no players, no NPCs.
                        -- NOT 4: that is LOCKED_PLAYER_INSIDE, it waits for an
                        -- entry that can never happen here, and client/rescue.lua
                        -- shipped it and drove the whole way unlocked.
                        nat(SetVehicleDoorsLocked, veh, tonumber(S.lockedState) or 2)
                        nat(SetEntityInvincible, veh, true)

                        -- ═══ AND INVINCIBLE DOES NOT COVER THE GLASS ═══
                        --
                        -- Owner, 2026-08-29: "we can break windshields by
                        -- shooting them at the store. I thought they were
                        -- [invincible]".
                        --
                        -- HE IS RIGHT AND SO IS THE CODE ABOVE.
                        -- SET_ENTITY_INVINCIBLE is a HEALTH flag: the car's body
                        -- and engine health stop falling, so it cannot be
                        -- destroyed. Windows, deformation and scratches are the
                        -- separate VISIBLE-DAMAGE system, and tyres are a third
                        -- one again -- which this repository already knew from
                        -- the other direction: client/rescue.lua has to call
                        -- SetVehicleTyresCanBurst explicitly on an ambulance
                        -- that is deliberately NOT invincible, and
                        -- config/rescue.lua's `tyresBulletproof` block is an
                        -- argument about exactly that separation.
                        --
                        -- So three more natives, and each covers a system
                        -- SetEntityInvincible does not:
                        --
                        --   VISIBLY DAMAGED -- the windows, the deformation and
                        --     the scratches. This is the one his bug is about.
                        --   PROOFS -- bullet, fire, explosion, collision, melee,
                        --     steam, p7, water, in that argument order. Belt to
                        --     the invincibility's braces: a proof refuses the
                        --     damage EVENT rather than absorbing its result, so
                        --     the car does not flinch, smoke or catch fire while
                        --     its health sits pinned.
                        --   TYRES -- the third system. A showroom car standing
                        --     on four flats is the same complaint as a broken
                        --     windshield.
                        --
                        -- ═══ NONE OF THIS FOLLOWS THE CAR HE BUYS ═══
                        --
                        -- It is applied HERE, to the display entity, and never
                        -- in BR.Shop.dress -- which is the one function both
                        -- cars go through. #224 is explicit: "After that it is
                        -- an ordinary car: it burns fuel, it can be destroyed,
                        -- anyone can steal it." A showroom protection that
                        -- reached the delivered car would be an indestructible
                        -- car in a match, which is a far worse bug than
                        -- breakable glass. tools/test_shop.lua asserts the
                        -- separation rather than trusting it.
                        nat(SetVehicleCanBeVisiblyDamaged, veh, false)
                        nat(SetEntityProofs, veh, true, true, true, true, true,
                            true, true, true)
                        nat(SetVehicleTyresCanBurst, veh, false)

                        -- ═══ AND THE GLASS IS A FOURTH SYSTEM, WHICH IS WHY
                        --     ALL THREE OF THOSE MISSED IT ═══
                        --
                        -- Owner, 2026-08-30, having played the fix above:
                        -- "showroom glass STILL shatters."
                        --
                        -- THE PREVIOUS ATTEMPT (aafe22a) WAS A REASONED GUESS
                        -- AND IT SAID SO AT THE TIME -- no primary source, one
                        -- working in-the-wild implementation. The reasoning was
                        -- that windows belong to the visible-damage system, and
                        -- that is what SET_VEHICLE_CAN_BE_VISIBLY_DAMAGED
                        -- governs: deformation, scratches, dirt, the paint. It
                        -- does not govern the windows, and the proofs do not
                        -- either -- a proof refuses a damage event against the
                        -- ENTITY, and a pane of glass shattering is not damage
                        -- to the entity.
                        --
                        -- ═══ THE MECHANISM, CITED THIS TIME ═══
                        --
                        -- Vehicle glass is its own collision, with its own
                        -- native to switch off:
                        --
                        --   _SET_DISABLE_VEHICLE_WINDOW_COLLISIONS
                        --   0x1087BC8EC540DAEB
                        --   void (Vehicle vehicle, BOOL toggle)
                        --   citizenfx/natives,
                        --     VEHICLE/SetDisableVehicleWindowCollisions.md
                        --
                        -- and that reference states the effect in the words the
                        -- bug is written in: with it enabled you cannot break
                        -- the vehicle's glass, bullets pass straight through it,
                        -- and it cannot be broken any other way either --
                        -- hitting included. Rockstar's own use is the NIGHTSHARK
                        -- with its armour-plate window mod fitted, which is
                        -- exactly this case: a car whose windows are not
                        -- supposed to break.
                        --
                        -- TRUE DISABLES THE COLLISION, which is the direction
                        -- that stops the breakage. `false` would restore it and
                        -- read as the fix while undoing it, so the value is the
                        -- whole of this line and the suite asserts the value.
                        --
                        -- ═══ AND IT DOES NOT FOLLOW THE CAR HE BUYS ═══
                        --
                        -- Same rule as the three above and for the same #224
                        -- sentence: it is applied here, to the display entity,
                        -- and never in BR.Shop.dress. A purchased car with
                        -- unbreakable windows is a fighting advantage bought
                        -- with Volts, which is the one thing the catalogue's
                        -- whole safety argument exists to prevent.
                        --
                        -- ═══ IF THIS ONE ALSO MISSES ═══
                        --
                        -- The console cannot answer it and neither can a test:
                        -- the native returns nothing and there is no read-back.
                        -- One playtest settles it -- shoot a windscreen on the
                        -- pad. If it still breaks, the remaining candidate is
                        -- that this build's glass is driven by the vehicle's own
                        -- damage model rather than by the window collision, and
                        -- the next thing to try is per-frame FIX_VEHICLE_WINDOW
                        -- on the display cars, which is a repair rather than a
                        -- prevention and is why it is not what shipped here.
                        nat(SetDisableVehicleWindowCollisions, veh, true)

                        -- ═══ ON THE GROUND BEFORE IT IS FROZEN, AND THE ORDER
                        --     IS THE ENTIRE FIX ═══
                        --
                        -- Owner, 2026-08-29: "sometimes the vehicles appear
                        -- floating off the ground. Can we use
                        -- PlaceObjectOnGroundProperly?"
                        --
                        -- ALMOST. PlaceObjectOnGroundProperly is the OBJECT
                        -- native -- it is what client/loot.lua settles crates
                        -- with -- and it does nothing to a vehicle. The
                        -- neighbouring one is SET_VEHICLE_ON_GROUND_PROPERLY,
                        -- which client/rescue.lua already uses twice on the
                        -- ambulance. Same idea, right archetype.
                        --
                        -- FREEZING FIRST WOULD HAVE MADE THIS A NO-OP. A frozen
                        -- entity does not move, so grounding after the freeze
                        -- would pin each car at exactly the height it was
                        -- floating at and report success. client/loot.lua
                        -- carries the same warning about its own props ("is
                        -- frozen by now, so PlaceObjectOnGroundProperly would do
                        -- nothing"), which is how this order was chosen rather
                        -- than discovered.
                        --
                        -- IT RETURNS A BOOL, SO IT GOES THROUGH isTrue. Reading
                        -- a native's 0 as a truth value is this project's most
                        -- shipped defect and it would silently invert this test.
                        --
                        -- AND IF IT FAILS, THE AUTHORED HEIGHT IS THE FALLBACK.
                        -- A car left wherever a failed grounding put it can be
                        -- under the pad; the surveyed z is the height a car of
                        -- that model came to rest at, so it is never
                        -- underground and never at waist height either.
                        --
                        -- ═══ AND NOTHING SETTLES ONTO GROUND THAT HAS NOT
                        --     ARRIVED ═══
                        --
                        -- The native immediately below needs RESIDENT
                        -- COLLISION, and this pad is built while the player is
                        -- still 1.36km away in the lobby. awaitCollision is
                        -- what turns "whether it worked depended on how fast
                        -- the world streamed" into "it waited until the world
                        -- was there". Everything after this line is unchanged;
                        -- the only difference is WHEN it runs.
                        local collOK, collMs = awaitCollision(veh, row, mine)
                        if mine ~= gen then
                            -- Abandoned mid-wait. This car is in nobody's
                            -- `cars` table yet, so teardown cannot reach it and
                            -- this is the only place it can be cleaned up.
                            if isTrue(DoesEntityExist(veh)) then
                                DeleteEntity(veh)
                            end
                            return
                        end
                        local bWait = false
                        do
                            local okW, w = pcall(IsEntityWaitingForWorldCollision,
                                                 veh)
                            bWait = okW and isTrue(w) or false
                        end

                        local okG, landed = pcall(SetVehicleOnGroundProperly, veh)
                        if not (okG and isTrue(landed)) then
                            -- ═══ THE RAW SURVEY, AND PLACED WITHOUT THE
                            --     OFFSET ═══
                            --
                            -- TWO FAULTS LIVED IN THE ONE LINE THIS REPLACES,
                            -- and they pushed the same way -- upward, into the
                            -- floating the branch exists to prevent.
                            --
                            -- SET_ENTITY_COORDS TAKES z AS WHERE THE BOTTOM OF
                            -- THE ENTITY GOES and lifts the car by its own
                            -- height to put it there; SET_ENTITY_COORDS_NO_
                            -- OFFSET is the same native without that lift, and
                            -- it is the one client/loot.lua reseats crates
                            -- with. An origin height handed to the offsetting
                            -- form is an origin height plus a car.
                            --
                            -- AND `startZ` IS THE SURVEY LESS THE DROP, which
                            -- is a starting height for a settle that has just
                            -- refused to happen. The authored z IS a settled
                            -- car's origin -- see config/shop.lua -- so a car
                            -- the engine would not place belongs at exactly
                            -- that number, with nothing added and nothing
                            -- taken off.
                            pcall(SetEntityCoordsNoOffset, veh, row.x + 0.0,
                                  row.y + 0.0, row.z + 0.0, false, false, false)
                            -- WHAT IT SAYS IS WHERE THE CAR IS. The line this
                            -- replaces printed startZ, which after the offset
                            -- lift was not a height any car was ever at -- so
                            -- the console was reporting a number that could not
                            -- be checked against anything.
                            print(('[br_core] shop: "%s" would not settle -- '
                                   .. 'placed at its surveyed z (%.2f); '
                                   .. 'collision %s after %dms')
                                :format(tostring(row.id), row.z + 0.0,
                                        collOK and 'loaded' or 'NEVER LOADED',
                                        collMs))
                        end

                        -- ═══ WHAT THE SETTLE PRODUCED, WRITTEN DOWN (#243) ═══
                        --
                        -- READ-ONLY BOOKKEEPING. Nothing places anything from
                        -- this table; /brshop is its only reader. It is here
                        -- because the one number nobody has is the height each
                        -- of thirteen different models CAME TO REST AT, and
                        -- that number exists for exactly one frame -- after
                        -- this it is either still true, in which case the car
                        -- is where the engine put it, or it is not, in which
                        -- case something moved a frozen car and we finally have
                        -- the before to compare the after against.
                        --
                        -- THE ENGINE'S OWN PER-MODEL ANSWER, NOT A GUESS. A
                        -- vehicle's origin is not at its wheels and the
                        -- origin-to-wheel distance differs per model, which is
                        -- why one authored constant cannot be right for all
                        -- thirteen. SET_VEHICLE_ON_GROUND_PROPERLY computes
                        -- that distance from the model's own wheels; reading
                        -- the coordinates straight back off a successful call
                        -- is a MEASUREMENT of it, and it is correct for a model
                        -- this code has never seen.
                        --
                        -- AND THE STREAMING STATE AT THE BUILD, WHICH IS THE
                        -- ONE THING NO COLUMN COULD PREVIOUSLY ANSWER. /brshop
                        -- asks the two collision natives when the command is
                        -- typed; by then the player is standing on the pad and
                        -- both say what a healthy pad says, whatever the world
                        -- looked like when the cars were made. These three are
                        -- that earlier moment, kept.
                        local okP, pz = pcall(GetEntityCoords, veh)
                        placed[row.id] = {
                            settled = (okG and isTrue(landed)) and true or false,
                            startZ  = startZ,
                            z       = (okP and pz and pz.z) or nil,
                            at      = GetGameTimer(),
                            collAtBuild = collOK and true or false,
                            waitAtBuild = bWait and true or false,
                            waitedMs    = collMs,
                        }

                        nat(FreezeEntityPosition, veh, true)
                        -- ...and the two that make "frozen" mean what a player
                        -- would expect it to mean: a frozen car can still be
                        -- shoved by a collision on some builds, and a car with
                        -- its engine running on the pad is a car making noise
                        -- nobody asked for.
                        nat(SetVehicleEngineOn, veh, false, true, true)
                        nat(SetVehicleDoorsLockedForAllPlayers, veh, true)

                        -- THE SEED THE BUILD STARTED WITH, not the file-level
                        -- `seed`. A reply landing mid-build swaps that local
                        -- out from under a thread that has already painted
                        -- eight cars, and the pad would end up in two matches'
                        -- colours at once. The generation token abandons this
                        -- thread on a re-seed; the argument is what makes the
                        -- cars it did build agree with each other in the
                        -- meantime.
                        BR.Shop.dress(veh, row, paintSeed)
                        cars[row.id] = veh
                    else
                        print(('[br_core] shop: could not build "%s" (%s)')
                            :format(tostring(row.id), tostring(row.model)))
                    end
                else
                    print(('[br_core] shop: model "%s" never loaded for row "%s"')
                        :format(tostring(row.model), tostring(row.id)))
                end
            else
                print(('[br_core] shop: "%s" is not a vehicle model on this build')
                    :format(tostring(row.model)))
            end
        end
    end)
end

--- Should the pad be standing right now?
---
--- WARMUP AND WARMUP ONLY, on both clocks -- the match's and this player's. A
--- spectator watching a warmup, or somebody sitting in the lobby while one runs,
--- is not standing in the showroom.
--- @return boolean
local function wantScene()
    if not BR.ShopSolve.enabled(S) then return false end
    if BR.State.match.state ~= BR.MatchState.WARMUP then return false end
    if BR.State.me.state ~= BR.PlayerState.WARMUP then return false end
    return true
end

--- The server naming the colours this match's showroom wears.
---
--- ═══ A DIFFERENT SEED IS A DIFFERENT SHOWROOM, SO IT REBUILDS ═══
---
--- The reconciler only asks while `seed` is nil, so in the ordinary case exactly
--- one answer arrives and this runs once. The case it is written for is the
--- untidy one: a reply for the PREVIOUS match landing a moment after a new
--- warmup started asking. Taking the first answer and keeping it would leave the
--- pad painted from a seed the server no longer holds -- and the car unpacked
--- later, dressed from the delivery's seed, would come out a different colour
--- with nothing anywhere to explain it.
---
--- So the newest answer wins and the pad is rebuilt under it. Repainting a
--- showroom nobody has bought from yet is free; the purchase is refused on the
--- server anyway if this player is not in a live warmup.
---
--- `not s` IS A NIL TEST, AND IT IS ONE ONLY BECAUSE 0 IS TRUTHY IN LUA.
--- math.tointeger answers nil for a payload carrying no `s` and 0 for a seed of
--- zero, which the server can genuinely mint -- it masks its roll to 32 bits.
--- Those two must not collapse: an `s == 0` guard, or a `tonumber(d.s) or 0`,
--- would refuse one match in four billion its showroom, and nobody would ever
--- reproduce it.
RegisterNetEvent('br:shop:seeded')
AddEventHandler('br:shop:seeded', function(d)
    if type(d) ~= 'table' then return end
    local s = math.tointeger(tonumber(d.s))
    if not s or seed == s then return end

    if seed ~= nil or built then teardown() end
    seed = s
end)

--- The scene, reconciled once a second.
---
--- A RECONCILER RATHER THAN TWO EVENT HANDLERS, and that is the difference
--- between a pad that is correct and a pad that is usually correct. Building on
--- the WARMUP edge and tearing down on the next one leaves every case that is
--- not an edge -- a player joining mid-warmup, a br_core restart, a state that
--- flapped while models were streaming -- to be handled by a handler that did
--- not run. Comparing want against have costs one comparison a second and has no
--- such cases.
---
--- SLOW BAND. The question changes at most twice a match.
---
--- ═══ AND THE SEED IS RECONCILED THE SAME WAY, FOR THE SAME REASON ═══
---
--- "ask once when the pad goes up" is the shape that fails: the answer can be
--- lost, the server can refuse it because this player's state has not caught up
--- yet, or br_core can restart mid-warmup with no edge left to fire on. Asking
--- again every second until an answer arrives has none of those cases, costs one
--- event per second per client for at most a beat or two, and STOPS THE MOMENT
--- IT IS ANSWERED -- `seed` being set is the whole of the condition.
BR.Loop.register(BR.Loop.SLOW, 'shop.scene', function()
    if wantScene() then
        if seed == nil then
            TriggerServerEvent('br:shop:seed')
            return
        end
        build(seed)
    elseif built or seed ~= nil then
        teardown()
        -- LEAVING WARMUP IS WHAT RESETS THE ALLOWANCE ON THIS SIDE. The server
        -- keys its own copy on the match id and is the authority; this is only
        -- what decides whether a plate is offered.
        spent = false
    end
end)

-- ---------------------------------------------------------------------------
-- The plate
-- ---------------------------------------------------------------------------

--- THE SHARED WORLD-PROMPT PAGE, WHICH IS THE FIFTH CONSUMER OF IT.
---
--- The crate, the pump, the revive and the heal station all draw on this one
--- browser, and client/ambheal.lua states the standing rule: "One browser for
--- every world prompt in the game." A DUI is a whole CEF instance, and a page
--- per car on the pad would be one browser per row of config.
---
--- WHAT THAT COSTS, SAID PLAINLY: one plate is up at a time -- the car the
--- keypress would act on. The owner asked for "DUIs on the front of the
--- vehicles"; this puts one on the front of the vehicle you are at. Every car
--- wearing its own price from across the lot needs a different mechanism (one
--- texture holding every row, drawn per car through DrawSpritePoly's UVs) and is
--- not built here.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Show or hide the plate.
---
--- ═══ THE COPY IS THE OWNER'S, VERBATIM, AND THERE IS NO OTHER COPY ═══
---
--- Owner, 2026-08-29: 'We need to draw DUIs on the front of the vehicles which
--- says "[model name] for sale" and the price.'
---
--- `label` is the subject and `hint` is the second line -- client/loot.lua's
--- split, which every other prompt in the game follows.
---
--- THE PRICE WAS A BARE NUMBER AND HE HAS NOW ASKED FOR THE WORD. Owner,
--- 2026-08-29: 'Change the green line to say "x Volts"'. The note that used to
--- sit here said a bare number was right because "adding a word to it would be
--- copy nobody asked for" -- which was true until he asked for it, and is the
--- reason the word arrives from BR.Config.Market.currency rather than being
--- typed into this file. That config line is where the currency's name lives and
--- its own comment says renaming it is that line plus the Ringmaster constant; a
--- literal here would quietly make it three places.
---
--- The key cap is the player's OWN binding, asked for by COMMAND rather than by
--- control -- client/loot.lua's fix, without which every prompt in the game said
--- E after a rebind.
--- ═══ SENT WHEN THE CAR CHANGES, NOT ONLY WHEN THE PLATE APPEARS ═══
---
--- This used to return early on `show == promptShown`, which is right for a
--- prompt that is only ever about ONE thing and wrong for a showroom. On the
--- owner's pad the cars are 3.25m apart and the reach is five, so walking down
--- the line NEVER drops the plate: `candidate` moved to the next car, the sprite
--- moved to the next car's bumper -- and the words on it still named the first
--- car and quoted the first car's price, because the only send happened when the
--- plate came up.
---
--- The player would then have read one price, pressed, and been charged another.
--- Both ends of that were "correct" in isolation, which is why it survived
--- review: the purchase resolved to the nearest car and so did the position. The
--- TEXT was the one thing that did not.
---
--- So the guard is on the PAIR -- shown, and shown FOR WHICH ROW -- and a row
--- change re-sends. Still a send on change rather than per tick; it is just that
--- the change that matters is not only up-versus-down.
--- @param show boolean
--- @param row table|nil
local function setPrompt(show, row)
    show = (show == true)
    local was = candidate
    candidate = show and row or nil
    if show == promptShown and candidate == was then return end
    local appeared = (show ~= promptShown)
    promptShown = show

    -- ═══ THE HUD'S VOLTS READOUT, WHICH IS UP FOR EXACTLY AS LONG AS A PLATE
    --     IS ═══
    --
    -- Owner, 2026-08-29: "when a DUI is shown at the shop, please show their
    -- current volts balance with NUI where the bullet rounds show."
    --
    -- ON THE SHOW EDGE ONLY, NOT ON EVERY ROW CHANGE. Walking from one car to
    -- the next re-sends the PLATE (its words change) and must not re-send this
    -- (its answer does not) -- the balance is the same number at every car on
    -- the pad, and pushing it thirteen times as somebody walks the line is
    -- thirteen HUD renders for one unchanged figure.
    --
    -- NO BALANCE ON THE WIRE. This carries a boolean. br_ui already holds the
    -- player's Volts -- it is what the Store screen renders, refreshed on every
    -- MARKET_STATE -- so sending it from here would be a second copy of one
    -- number, free to disagree with the shop screen. This side knows WHETHER;
    -- the side that already knows the figure supplies it.
    if appeared then
        TriggerEvent('br:ui:sendLocal', 'shopplate', { show = show })
    end

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = (S.signLabel or '%s for sale'):format(BR.ShopSolve.nameOf(row)),
        hint  = BR.ShopSolve.priceLine(row.price,
                                       BR.Config.Market and BR.Config.Market.currency),
        key   = BR.Native.keyLabelForCommand('brinteract', 51),
        ring  = false,
        -- ═══ THE PRICE, LARGE AND IN THE CURRENCY'S OWN COLOUR ═══
        --
        -- Owner, 2026-08-29: "the price text needs to be increased in font size
        -- and make it green. It should be large."
        -- Owner, 2026-08-30: "the volts text should be orange - the same color
        -- we show in the market page."
        --
        -- SENT AS A FLAG, NOT AS A STYLE. `hintBig` asks the page for its price
        -- treatment and the page owns what that means; a font size sent from
        -- Lua would put the plate's typography in two files, and the same hint
        -- line is shared with the crate, the pump, the revive and the heal
        -- station -- none of which asked to grow.
        --
        -- THE COLOUR IS THE MARKET PAGE'S OWN TOKEN, RESOLVED BY THE HUD'S OWN
        -- CASCADE. `--color-royale-accent2` is what Market.tsx paints the
        -- balance plate and every affordable price button with, so this is
        -- literally "the same color we show in the market page" rather than a
        -- hex that matches it today. It arrives from br_ui (see BR.Dui.volts)
        -- for the same reason the green did: index.css is the only place a
        -- colour in this game is written down, and a DUI is a separate document
        -- that cannot read it.
        --
        -- THE GREEN IS GONE FROM HERE ENTIRELY, and BR.Dui.hp with it. It is
        -- still the right colour for a HOLD prompt and the other four consumers
        -- of this page are untouched; it was never right for a price, and the
        -- owner has now said which colour a price is.
        --
        -- NIL IS A LEGITIMATE ANSWER and the page falls back to its own colour.
        -- A br_core restart mid-session sits here until br_ui next applies its
        -- settings, and a price in the default colour is a far better failure
        -- than no price.
        hintBig    = true,
        hintColour = (BR.Dui.volts and BR.Dui.volts()) or nil,

        -- ═══ AND THE CAR'S NAME, A BIT LARGER ═══
        --
        -- Owner, 2026-08-30: "the title of the vehicle should be a bit larger."
        -- A FLAG for the same reason `hintBig` is one: the page decides what
        -- "larger" is in pixels, and the four other prompts sharing this browser
        -- keep the size they have.
        labelBig   = true,
    })
end

--- Where on a car its sign stands, IN THE CAR'S OWN COORDINATES.
---
--- ═══ LOCAL OFFSETS RATHER THAN A WORLD POINT, WHICH IS #236 ═══
---
--- This used to return world x/y/z, because BR.Dui.drawWorld took a point and
--- squared a sprite to the camera there. A sign has to know the car's axes, not
--- just one of its points -- so the two offsets go to BR.Dui.drawFace and it
--- resolves all four corners against the entity. Nothing here computes a world
--- coordinate any more, and the plate cannot drift off the bodywork as a result.
---
--- READ OFF THE MODEL rather than hardcoded, IN BOTH AXES. It always was
--- forwards -- `front` is the box's nose, so a Sanchez and a Bison each get
--- their plate clear of their own bumper -- and the height was one authored
--- 1.15 above the car's origin, which is a saloon's number applied to a monster
--- truck. Owner, 2026-08-29: "change the DUI to draw at the elevation of the
--- vehicle's bumper." BR.ShopSolve.signHeight is that derivation, and it is in
--- br_lib because a height a test can evaluate is worth more than one only a
--- playtest can see.
---
--- GetModelDimensions is a model-table lookup and this runs every frame the
--- plate is up, so the answer is cached per model -- client/dui.lua's
--- drawOnEntity caches its own for the same reason. The cache holds the BOX and
--- not the derived height, so re-tuning the two config numbers takes effect on
--- a br_lib reload rather than surviving in a cache keyed by model.
---
--- BOTH ARE READ OFF THE MODEL IN ITS OWN AXES AND SPENT LEVEL. drawFace lays
--- `oy` along the car's flattened heading and `oz` straight up the world, so a
--- vehicle that leans keeps its sign on its centreline at the bumper height its
--- box says -- rather than swinging the height out sideways with the lean.
--- @param veh integer
--- @return number|nil oy  metres in front of the model's own nose
--- @return number|nil oz  metres above the model origin: its bumper height
local function signOffsets(veh)
    local model = GetEntityModel(veh)
    local d = DIMS[model]
    if not d then
        local a, b = GetModelDimensions(model)
        if not a or not b then return nil end
        d = { front = b.y, bottom = a.z, top = b.z }
        DIMS[model] = d
    end
    return d.front + (tonumber(S.signForwardM) or 0.4),
           BR.ShopSolve.signHeight(d.bottom, d.top, S.signBumperFrac, S.signLift)
end

--- Is this row's car actually standing on the pad on THIS client?
---
--- A row whose model never streamed has no entity, and a plate on a car that is
--- not there is a price for something a player cannot see. Handed to
--- BR.ShopSolve.nearest as its `present` filter so the SELECTION skips it,
--- rather than being checked after the fact -- picking the nearest row and then
--- discovering it has no car would offer nothing while a perfectly good car
--- stood two metres further on.
--- @param row table
--- @return boolean
local function standing(row)
    local veh = cars[row.id]
    return (veh ~= nil and veh ~= 0 and isTrue(DoesEntityExist(veh)))
end

--- Which car is the player standing at?
---
--- THE NEAREST ONE IN REACH, AND THE ARITHMETIC IS BR.ShopSolve.nearest's
--- RATHER THAN THIS FILE'S. It used to be a loop here, which meant the one rule
--- that decides which car somebody's Volts are spent on lived in a client file
--- no test can execute. It is a pure function over the catalogue now, and
--- tools/test_shop.lua stands a player between the owner's two closest cars and
--- checks which one comes back.
---
--- WHY NEAREST AND NOT "ANY IN REACH": on the surveyed pad the tightest pair is
--- 3.25m apart, so there is no reach radius that puts one car in range and not
--- its neighbour -- it would have to be under 1.63m, which is inside both cars.
--- The full argument is in the header of BR.ShopSolve.nearest.
---
--- ON THE TICK BAND, NOT THE FRAME BAND. Walking speed is about two metres a
--- second; ten passes a second is already finer than the question can change,
--- and this walks the whole catalogue.
BR.Loop.register(BR.Loop.TICK, 'shop.prompt', function()
    if spent or not built or not wantScene() then setPrompt(false) return end

    local c = GetEntityCoords(PlayerPedId())
    local best = BR.ShopSolve.nearest(rows, c.x, c.y,
                                      tonumber(S.reachM) or 4.0, standing)

    if not best then setPrompt(false) return end
    setPrompt(true, best)
end)

--- ...and drawing it, which has to be per frame: BR.Dui.drawFace is a pair of
--- DrawSpritePoly calls and a poly lasts exactly one frame. The TICK pass
--- decides WHETHER; this decides WHERE.
---
--- ═══ drawFace, NOT drawWorld (#236) ═══
---
--- Owner, 2026-08-30: "The store DUIs are dynamically sized and face the player.
--- I want them to be stationary, with the DUI displayed on the front face of the
--- vehicle, akin to a yard sign."
---
--- Both complaints are one native pair. drawWorld is SetDrawOrigin +
--- DrawSprite: the origin projects a world point to the screen and the sprite is
--- sized in SCREEN fractions, so it is a billboard AND it holds a constant share
--- of the display at every distance. Neither is a parameter on that function.
--- drawFace builds the quad in the world from the CAR'S OWN HEADING instead, in
--- metres -- so it turns with the car, stays put, and gets smaller as you walk
--- away because that is what a thing in the world does.
---
--- ITS HEADING AND NOT ITS WHOLE POSE, which is the 2026-08-30 follow-up: the
--- sanchez leans on its kickstand and its price used to lean with it. drawFace
--- flattens the car's forward vector and stands the sign up the world's Z, so
--- both offsets below are read level -- see its own body for the argument.
BR.Loop.register(BR.Loop.FRAME, 'shop.draw', function()
    if not promptShown or not candidate then return end
    local veh = cars[candidate.id]
    -- RE-CHECKED, because reading the coordinates of a dead handle throws -- and
    -- in a frame callback five of those cost the whole band.
    if not veh or veh == 0 or not isTrue(DoesEntityExist(veh)) then return end

    local oy, oz = signOffsets(veh)
    if not oy then return end
    BR.Dui.drawFace(promptPage(), veh, oy, oz,
                    tonumber(S.signWidthM) or 0.75)
end)

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

--- THE PRESS ACTS ON WHAT WAS DRAWN, never on a fresh search. #128 again: the
--- prompt and the action must resolve once, or a player presses while looking at
--- one car and buys the other.
BR.Keys.on('interact', function(pressed)
    if not pressed then return end
    if spent or not promptShown then return end
    local row = candidate
    if not row then return end

    -- THE CLIENT NAMES A CAR AND SAYS NOTHING ELSE. No price, no balance, no
    -- claim about what state it is in -- every one of those is resolved on the
    -- server (server/shop.lua), which is server/market.lua's rule for the
    -- storefront applied to the second one.
    TriggerServerEvent('br:shop:buy', { id = row.id })
end)

--- The purchase landed.
---
--- THE EXISTING PICKUP CUE AND NOTHING NEW. BR.Config.Loot.pickupSound is what
--- already fires whenever something lands in an inventory, which is what has
--- just happened; config/audio.lua's rule is that two actions sounding identical
--- is worse than one sounding wrong, and a purchase IS a pickup.
---
--- BY KEY, THROUGH BR.Sfx, AND NOT AS A SET/NAME PAIR WRITTEN HERE.
--- tools/verify.sh refuses an inlined pair outside three files and the reason is
--- good: a pair nothing knows the key of cannot be auditioned with /brsfx,
--- cannot be re-pointed with `brsfx bind`, and fails silently when the set is
--- wrong. config/shop.lua installs `shop.buy` as THE SAME TABLE as the loot
--- pickup rather than a copy of it, so there is still exactly one authored pair.
---
--- THE TOAST IS THE SERVER'S. It arrives down the ordinary notify path with the
--- owner's sentence on it; nothing here speaks.
RegisterNetEvent('br:shop:bought')
AddEventHandler('br:shop:bought', function()
    spent = true
    setPrompt(false)
    if BR.Sfx and S.cue then BR.Sfx.play(S.cue) end
end)

-- ---------------------------------------------------------------------------
-- Unpacking
-- ---------------------------------------------------------------------------

--- The car the server just built for this player: adopt it, dress it, sit in it.
---
--- ═══ CONTROL FIRST, BECAUSE EVERY LINE AFTER IT IS A WRITE ═══
---
--- The server made this vehicle, so this machine does not own it by
--- construction, and a write to an entity you do not control is a local-only
--- change that the owner's next sync undoes. client/rescue.lua's ambulance
--- carries the full write-up; the loop is bounded because
--- NetworkRequestControlOfEntity returns whether the REQUEST was accepted rather
--- than whether control arrived, so one call is a coin flip.
---
--- NOT FATAL IF CONTROL NEVER COMES. An undressed car is still a car, the player
--- still paid for it, and answer 3 says there is no second attempt. It is logged
--- -- loudly, because a car that arrives in the wrong colour is precisely the
--- report this feature exists to never produce.
RegisterNetEvent('br:shop:dress')
AddEventHandler('br:shop:dress', function(d)
    if type(d) ~= 'table' then return end
    local netId = math.tointeger(tonumber(d.n) or 0)
    local row = BR.ShopSolve.rowById(rows, tostring(d.row or ''))
    -- ═══ THE SERVER'S SEED, AND THE LOCAL ONE IS DELIBERATELY NOT CONSULTED
    --     ═══
    --
    -- By the time anybody uses this item the pad is long gone and `seed` is nil,
    -- so falling back to it would mean falling back to nothing. This number
    -- travelled with the delivery precisely so the car can be painted from the
    -- same input the showroom was, minutes after the showroom stopped existing.
    --
    -- ABSENT IS ALLOWED and means the authored colour -- server/shop.lua sends
    -- no seed when the match has none (a br_core restart mid-match) and says so
    -- on its own console. A car in its config colour beats no car.
    local paintSeed = math.tointeger(tonumber(d.s))
    if not netId or netId <= 0 or not row then
        print(('[br_core] shop: unusable delivery (%s / %s)')
            :format(tostring(d.n), tostring(d.row)))
        return
    end

    Citizen.CreateThread(function()
        -- ═══ WAIT FOR THE CLONE ═══
        --
        -- The entity exists on the server and is bucketed before this message is
        -- sent, but OneSync only clones what is RELEVANT -- and relevancy is
        -- decided on distance, which is five metres here. So this is a short
        -- wait for a message ordering rather than the 825-metre problem the
        -- ambulance had, and there is deliberately no culling-radius override.
        local veh = nil
        local t0 = GetGameTimer()
        repeat
            if NetworkDoesNetworkIdExist == nil
               or isTrue(NetworkDoesNetworkIdExist(netId)) then
                local ok, ent = pcall(NetworkGetEntityFromNetworkId, netId)
                if ok and ent and ent ~= 0 and isTrue(DoesEntityExist(ent)) then
                    veh = ent
                end
            end
            if veh then break end
            Citizen.Wait(50)
        until GetGameTimer() - t0 > (tonumber(S.adoptMs) or 5000)

        if not veh then
            -- THE FAILURE ANSWER 3 IS ABOUT, MADE LEGIBLE. The item is spent,
            -- nothing is refunded, and this line is the difference between "the
            -- car never existed" and "the car existed and never reached me" --
            -- which is exactly the distinction citizenfx/fivem#2623 turns on.
            print(('^1[br_core] shop: net id %d never became a "%s" here after '
                   .. '%dms -- the item is spent^7')
                :format(netId, row.id, GetGameTimer() - t0))
            return
        end

        local tc = GetGameTimer()
        while not isTrue(NetworkHasControlOfEntity(veh))
              and GetGameTimer() - tc < (tonumber(S.controlMs) or 3000) do
            NetworkRequestControlOfEntity(veh)
            Citizen.Wait(50)
        end
        if not isTrue(NetworkHasControlOfEntity(veh)) then
            print(('^3[br_core] shop: no control of "%s" after %dms -- it may '
                   .. 'not look the way it did in the showroom^7')
                :format(row.id, GetGameTimer() - tc))
        end

        -- THE SAME FUNCTION THE SHOWROOM CAR WAS DRESSED BY, over the same row
        -- AND THE SAME SEED. Two identical inputs, one function: the two cars
        -- are not compared, they are computed the same way twice.
        BR.Shop.dress(veh, row, paintSeed)

        -- ...AND NOTHING ELSE. No freeze, no lock, no invincibility: those three
        -- belong to the showroom and to nothing after it. #224: "After that it
        -- is an ordinary car: it burns fuel, it can be destroyed, anyone can
        -- steal it."
        --
        -- "spawn the vehicle which they purchased WITH THEM IN THE DRIVER'S
        -- SEAT" -- owner, 2026-08-29. Seat -1 is the driver.
        nat(SetVehicleEngineOn, veh, true, true, false)
        local ped = PlayerPedId()
        if ped and ped ~= 0 and not isTrue(IsPedInAnyVehicle(ped, false)) then
            nat(SetPedIntoVehicle, ped, veh, -1)
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- The measurement (#243)
-- ---------------------------------------------------------------------------

--- ═══ "PLEASE RESEARCH THIS AND STOP GUESSING" -- owner, 2026-08-30 ═══
---
--- He is right that `groundDropM = 0.5` is a guess, and this command is what
--- replaces the guess with a reading. IT CHANGES NOTHING ABOUT WHERE A CAR
--- ENDS UP: every native it calls is a getter, it writes to no entity, and the
--- drop is still 0.5 in config/shop.lua after it.
---
--- ═══ THERE ARE TWO REPORTS AND THEY ARE PROBABLY TWO FAULTS ═══
---
--- 2026-08-30, earlier: "After seeing the shop once in warmup, and going
--- outside its focus area (cell/culling radius), then coming back, all the
--- vehicles are floating off the ground again at waist level." SHOP-WIDE, and
--- it needs a stream-out and a stream-in to appear.
---
--- 2026-08-30, after the drop shipped: "Seems lowering the vehicles just put
--- some through the ground but some are still floating." A SPLIT, and it is
--- there on a first look.
---
--- One diagnosis was written that merged them and it did not survive review:
--- twelve of the thirteen rows are within about ten metres of a warmup spawn,
--- so "its collision had not streamed when we made it" cannot be what is wrong
--- with twelve cars a player is standing next to. Only `veto` is far enough
--- away (about 159m from the nearest spawn) for that story to fit. So the two
--- reports are asked two different questions here and the columns are laid out
--- to keep them apart.
---
--- ═══ WHAT EACH FAULT LOOKS LIKE IN THE OUTPUT ═══
---
--- A HEALTHY ROW: `built` and `now` agree to the centimetre, `d-blt` is 0.00,
--- `gz` answers, `hgt` is about 0.00, `whls` is Y.
---
--- FAULT (a), THE SPLIT: `built` and `now` still agree -- nothing moved -- but
--- `d-blt` being 0.00 next to an `hgt` that is not 0.00 says the car came to
--- rest in the wrong place and stayed there. A NEGATIVE `hgt` with `whls` N is
--- a car in the tarmac; a positive one is a car above it. If those two signs
--- appear on different rows of one printout, the constant is the fault: one
--- number cannot be the origin-to-wheel distance of thirteen different models.
---
--- FAULT (b), THE STREAM ROUND TRIP: run it at the pad, leave, come back, run
--- it again. If `now` has moved away from `built` between the two printouts,
--- something moved a frozen car and `d-blt` is the first measurement anybody
--- has of it. If `now` is IDENTICAL both times and the cars still look wrong on
--- screen, then the position is not what changed and the next place to look is
--- what is being drawn -- which is a different investigation, and knowing which
--- one to open is the entire value of this command.

--- HOW FAR ABOVE THE SURVEYED z THE DIAGNOSTIC PROBE STARTS ITS SEARCH DOWNWARD.
---
--- GET_GROUND_Z_FOR_3D_COORD answers with the highest ground BELOW the point it
--- is handed, so a probe started under the surface can only answer with
--- something lower or with nothing at all -- client/loot.lua's PROBE_FROM_Z
--- carries the write-up and the playtest that produced it ("hillside loot just
--- spawned below the map instead"). The pad is an apron at z 3.30 to 4.30 and
--- nothing on this island stands fifty metres over it, so this clears the
--- surface from above without reaching down past it from inside a roof.
---
--- IT IS A PROBE HEIGHT, NOT AN OFFSET. Nothing is placed at it.
local PROBE_LIFT_M = 50.0

--- One ground probe, or an honest account of why there is no answer.
---
--- THE FIRST RETURN IS A BOOL AND IT GOES THROUGH isTrue. Cfx documents the
--- native as answering false when the coordinates are outside the client's
--- render distance (citizenfx/natives, MISC/GetGroundZFor_3dCoord.md: "This
--- native can only calculate the elevation when the coordinates are within the
--- render distance of the client") -- which is the exact condition this command
--- exists to separate from a wrong height. Reading its 0 as truth would print
--- "no answer" as an answer of 0.00, and 0.00 is sea level on this map, so it
--- would read as a plausible number rather than as a refusal.
--- @param fn any
--- @param x number
--- @param y number
--- @param fromZ number
--- @return boolean|nil hit  nil when this build has no such native
--- @return number|nil z
local function probe(fn, x, y, fromZ)
    if type(fn) ~= 'function' then return nil, nil end
    -- includeWater false: we want the apron, not the sea over it.
    local okc, hit, gz = pcall(fn, x, y, fromZ, false)
    if not okc then return nil, nil end
    if not isTrue(hit) then return false, nil end
    return true, tonumber(gz) or 0.0
end

--- The excluding-objects probe, under whichever name this build exports it.
---
--- WHY ASK IT AT ALL. GET_GROUND_Z_FOR_3D_COORD includes props in what it will
--- call ground; GET_GROUND_Z_EXCLUDING_OBJECTS_FOR_3D_COORD does not
--- (0x9E82F0F362881B29, alias _GET_GROUND_Z_FOR_3D_COORD_2, citizenfx/natives
--- MISC/GetGroundZExcludingObjectsFor3dCoord.md). If the two columns AGREE, the
--- cars are standing on map geometry and the next round's fix can use either.
--- If they DISAGREE, the surface under the showroom is a placed object, and
--- that changes which native the fix must ask -- which is not something anyone
--- can settle by looking at the pad.
---
--- TWO SPELLINGS, AND WHICH ONE IS LIVE IS NOT VERIFIED. FiveM's Lua name comes
--- from a mechanical conversion that cannot capitalise a word beginning with a
--- digit, which is why its neighbour is `GetGroundZFor_3dCoord` and not
--- `GetGroundZFor3dCoord`. The underscore form is the likelier of the two; both
--- are asked for, and if neither exists the column prints `n/a` rather than
--- pretending the probes disagreed.
--- @return any
local function groundZNoObjects()
    local f = GetGroundZExcludingObjectsFor_3dCoord
    if type(f) == 'function' then return f end
    return GetGroundZExcludingObjectsFor3dCoord
end

--- A metre reading, or a dash where there is nothing to read.
---
--- "-0.00" IS NOT A READING AND IT IS THE ONE THIS COMMAND WOULD PRODUCE MOST.
--- Every delta here is a difference of two floats that are meant to be equal,
--- so a car that has not moved answers with a value a hair under zero about
--- half the time -- and "-0.00" in a column headed d-blt reads as "it has sunk
--- a little", which is the opposite of what it means. At two decimals the
--- number IS zero; it is printed as zero.
--- @param v number|nil
--- @return string
local function m(v)
    if type(v) ~= 'number' then return '-' end
    local s = ('%.2f'):format(v)
    if s == '-0.00' then return '0.00' end
    return s
end

--- A probe result as a column.
--- @param hit boolean|nil
--- @param z number|nil
--- @return string
local function probeText(hit, z)
    if hit == nil then return 'n/a' end
    if not hit then return 'NONE' end
    return m(z)
end

--- A native BOOL as a column, with "this build has no such native" kept
--- distinct from "the native said no". Those two have been confused on this
--- project before and they mean opposite things to a reader.
--- @param fn any
--- @param ... any
--- @return string
local function boolText(fn, ...)
    if type(fn) ~= 'function' then return 'n/a' end
    local okc, v = pcall(fn, ...)
    if not okc then return 'ERR' end
    return isTrue(v) and 'Y' or 'N'
end

--- A BOOL THIS FILE RECORDED EARLIER, as a column.
---
--- NOT boolText. That one CALLS a native now; this one reads a value taken at
--- the build and kept, so "there is no record" (a car built before the ledger
--- learned to keep it, or a row that never built) has to stay distinct from
--- "the answer was no". Collapsing those two would make an unrecorded car read
--- as one that was built into an empty world, which is the exact claim these
--- columns exist to make.
--- @param v boolean|nil
--- @return string
local function yn(v)
    if v == nil then return '-' end
    return v and 'Y' or 'N'
end

--- Everything about where the thirteen cars are, printed at once.
---
--- CONSOLE ONLY. Nothing here draws, notifies, or speaks to a player.
RegisterCommand('brshop', function()
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local gzx = groundZNoObjects()

    local nCars = 0
    for _ in pairs(cars) do nCars = nCars + 1 end

    print('=== shop (client) ===')
    print(('  scene %s   match %s   me %s   rows %d   cars %d')
        :format(built and 'BUILT' or 'down',
                tostring(BR.State.match.state), tostring(BR.State.me.state),
                #rows, nCars))

    -- ═══ THE PAINT SEED, AND THE COLOUR IT RESOLVES EACH ROW TO ═══
    --
    -- The only record of why a car is the colour it is. A player reporting "my
    -- car came out the wrong colour" is reporting a disagreement between two
    -- numbers -- this seed and the one the delivery carried -- and neither of
    -- them is visible anywhere else. The server prints its own copy at the roll,
    -- so the two can be put side by side.
    --
    -- `paint` READS THE SHIPPED PALETTE, so a row printing `-` here is a row the
    -- roll is not touching: the ambulance, or every row if `palette` is empty.
    local paints = {}
    for _, row in ipairs(rows) do
        local c = BR.ShopSolve.paint(row, seed, S.palette)
        paints[#paints + 1] = ('%s %s'):format(tostring(row.id),
                                               c and tostring(c) or '-')
    end
    print(('  paint seed %s   palette %d   %s')
        :format(seed and tostring(seed) or 'NOT YET ANSWERED',
                type(S.palette) == 'table' and #S.palette or 0,
                table.concat(paints, ', ')))

    -- ═══ THE DISTANCE LINE, SO A READING TAKEN FROM THE WRONG PLACE SAYS SO ═══
    --
    -- "Focus area" is the engine's own word for the streaming volume, and a
    -- ground probe is documented as only answering inside the client's render
    -- distance. So a printout taken from across the island is a printout of a
    -- world that is not loaded, and every NONE in it means nothing. This line
    -- is what lets the second reading of the pair be recognised as one taken on
    -- the way back rather than one taken at the cars.
    local nearId, nearD, farId, farD
    for _, row in ipairs(rows) do
        local d = BR.Dist(p.x, p.y, row.x + 0.0, row.y + 0.0)
        if not nearD or d < nearD then nearD, nearId = d, row.id end
        if not farD  or d > farD  then farD,  farId  = d, row.id end
    end
    if nearId then
        print(('  you   %.2f, %.2f, %.2f   nearest row %s at %.1fm   '
               .. 'farthest %s at %.1fm')
            :format(p.x, p.y, p.z,
                    tostring(nearId), nearD, tostring(farId), farD))
    else
        print(('  you   %.2f, %.2f, %.2f   (the catalogue is empty on this '
               .. 'client)'):format(p.x, p.y, p.z))
    end
    print(('  probe from the surveyed z + %.1fm, includeWater false   '
           .. 'drop groundDropM %.2fm   collision budget %dms   '
           .. 'excl-objects native %s')
        :format(PROBE_LIFT_M, tonumber(S.groundDropM) or 0.0,
                tonumber(S.collisionWaitMs) or 0,
                type(gzx) == 'function' and 'present' or 'ABSENT'))

    -- TWO COLLISION GROUPS, AND THE SECOND ONE IS THE READING THAT MATTERS.
    -- `coll`/`wait`/`whls` are asked NOW, from wherever the player is standing,
    -- minutes after the pad went up. `b-coll`/`b-wait`/`b-ms` are what the same
    -- two natives said AT THE BUILD, plus how long that car actually waited for
    -- them. A pad built into an empty world and a pad built onto real ground
    -- are indistinguishable in the first group by the time anybody types this,
    -- and that is what the first reading of this command got wrong.
    print(('  %-11s %-11s %6s %6s %6s %6s %6s | %6s %6s %6s | %-4s %-4s %-4s '
           .. '| %-6s %-6s %6s | %s')
        :format('id', 'model', 'survey', 'built', 'now', 'd-srv', 'd-blt',
                'gz', 'gz-x', 'hgt', 'coll', 'wait', 'whls',
                'b-coll', 'b-wait', 'b-ms', 'pitch/roll/yaw'))

    local settled, answered, moved = 0, 0, 0

    for _, row in ipairs(rows) do
        local veh  = cars[row.id]
        local rec  = placed[row.id]
        local live = (veh ~= nil and veh ~= 0 and isTrue(DoesEntityExist(veh)))

        -- WHERE IT IS NOW, WHICH IS THE ONLY FIGURE HERE THAT IS NOT A MEMORY.
        local nowZ
        if live then
            local okc, c = pcall(GetEntityCoords, veh)
            if okc and c then nowZ = c.z end
        end

        local builtZ = rec and rec.z or nil
        local dSurv  = nowZ and (nowZ - (row.z + 0.0)) or nil
        local dBuilt = (nowZ and builtZ) and (nowZ - builtZ) or nil

        -- THE PROBE IS FIRED AT THE ROW'S x/y AND NOT AT THE CAR'S. They are
        -- the same point unless something has slid a car sideways, and asking
        -- about the authored coordinate is what makes a NONE mean "the world is
        -- not resident under his survey" rather than "the world is not resident
        -- under wherever this car has ended up".
        local fromZ = row.z + 0.0 + PROBE_LIFT_M
        local hit,  gz  = probe(GetGroundZFor_3dCoord, row.x + 0.0, row.y + 0.0, fromZ)
        local hitX, gzZ = probe(gzx, row.x + 0.0, row.y + 0.0, fromZ)

        -- HOW FAR OFF THE GROUND THE ENGINE THINKS IT IS. This is the one
        -- number in the row that owes nothing to the survey, to the drop, or to
        -- anything this repository authored -- so it is the column to read when
        -- the others are in dispute.
        local hgt
        if live and type(GetEntityHeightAboveGround) == 'function' then
            local okh, h = pcall(GetEntityHeightAboveGround, veh)
            if okh then hgt = tonumber(h) end
        end

        -- COLLISION IS ASKED ABOUT THE ENTITY, NOT THE COORDINATE, and
        -- client/loot.lua explains why at length: there is no coord-taking form
        -- of the question, and a ground probe cannot stand in for it because
        -- terrain streams first and answers yes on its own.
        local coll = live and boolText(HasCollisionLoadedAroundEntity, veh) or '-'
        local wait = live and boolText(IsEntityWaitingForWorldCollision, veh) or '-'
        local whls = live and boolText(IsVehicleOnAllWheels, veh) or '-'

        local rot = '-'
        if live and type(GetEntityRotation) == 'function' then
            local okr, r = pcall(GetEntityRotation, veh, 2)
            if okr and r then
                rot = ('%.1f/%.1f/%.1f'):format(r.x, r.y, r.z)
            end
        end

        -- WHAT THE WORLD LOOKED LIKE WHEN THIS CAR WAS MADE, from the ledger.
        -- A row with no ledger entry -- a pad that has been taken down, a build
        -- that never reached this row -- is three dashes, and `yn` is what
        -- keeps that distinct from three answers of "no".
        local led   = rec or {}
        local bColl = yn(led.collAtBuild)
        local bWait = yn(led.waitAtBuild)
        local bMs   = led.waitedMs and ('%d'):format(led.waitedMs) or '-'

        print(('  %-11s %-11s %6.2f %6s %6s %6s %6s | %6s %6s %6s | %-4s %-4s '
               .. '%-4s | %-6s %-6s %6s | %s')
            :format(tostring(row.id), tostring(row.model), row.z + 0.0,
                    m(builtZ), m(nowZ), m(dSurv), m(dBuilt),
                    probeText(hit, gz), probeText(hitX, gzZ), m(hgt),
                    coll, wait, whls, bColl, bWait, bMs, rot))

        if rec and rec.settled then settled = settled + 1 end
        if hit then answered = answered + 1 end
        if dBuilt and math.abs(dBuilt) > 0.01 then moved = moved + 1 end
    end

    -- THE VERDICT LINE, WHICH IS THREE COUNTS AND NO OPINION. `settled` is how
    -- many the engine grounded when the pad went up; `answered` is how much of
    -- the world is resident right now; `moved` is how many cars are somewhere
    -- other than where they were left. A healthy pad reads N, N, 0.
    print(('  settled at build %d/%d   probe answering now %d/%d   '
           .. 'moved since build %d')
        :format(settled, #rows, answered, #rows, moved))
end, false)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- REGISTERED HERE RATHER THAN AT CONFIG LOAD. config/loot.lua builds
--- BR.Config.ConsumableById with a plain assignment, so anything registered
--- before that line is destroyed by it -- and the order a `config/*.lua` glob is
--- expanded in is the platform's business, not this file's. By the time br_core
--- loads, every br_lib script has run whatever order it ran in.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    local rejects
    rows, rejects = BR.Config.Shop.register(BR.Config.Shop.refusedReason)
    for _, r in ipairs(rejects) do
        print(('^3[br_core] shop: row "%s" is not for sale -- %s^7')
            :format(r.id, r.why))
    end
end)

--- A pad left standing into the next match is a pad on the wrong island.
AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then teardown() end
end)
