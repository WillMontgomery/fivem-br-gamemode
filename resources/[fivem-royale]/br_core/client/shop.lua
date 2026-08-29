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
-- NOTHING ABOUT AN APPEARANCE EVER CROSSES THE WIRE. The purchase carries a
-- catalogue id, the inventory item carries an item id, and the delivery message
-- carries a net id and a catalogue id. Every client already holds
-- config/shop.lua, because config/ is a shared_script -- so the car is
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

--- Is the showroom standing?
local built = false

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
--- @param veh integer
--- @param row table
function BR.Shop.dress(veh, row)
    if not veh or veh == 0 or not isTrue(DoesEntityExist(veh)) then return end
    local a = BR.ShopSolve.appearance(row)

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
    for id, veh in pairs(cars) do
        if veh and veh ~= 0 and isTrue(DoesEntityExist(veh)) then
            DeleteEntity(veh)
        end
        cars[id] = nil
    end
end

--- Put the cars on the pad.
---
--- ONE THREAD FOR THE WHOLE SHOWROOM, not one per car: model streaming yields,
--- and a burst of RequestModel in one frame is how a dense scene turns into a
--- stutter (client/loot.lua's drain makes the same trade).
local function build()
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
                    -- LOCAL. NEVER NETWORKED. See the header, and client/bus.lua
                    -- for the same two `false`s in the same positions.
                    local veh = CreateVehicle(model, row.x + 0.0, row.y + 0.0,
                                              row.z + 0.0,
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
                        nat(FreezeEntityPosition, veh, true)
                        -- ...and the two that make "frozen" mean what a player
                        -- would expect it to mean: a frozen car can still be
                        -- shoved by a collision on some builds, and a car with
                        -- its engine running on the pad is a car making noise
                        -- nobody asked for.
                        nat(SetVehicleEngineOn, veh, false, true, true)
                        nat(SetVehicleDoorsLockedForAllPlayers, veh, true)

                        BR.Shop.dress(veh, row)
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
BR.Loop.register(BR.Loop.SLOW, 'shop.scene', function()
    if wantScene() then
        build()
    elseif built then
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
--- split, which every other prompt in the game follows. The price is a bare
--- number because that is how every Volts figure in this game is written; adding
--- a word to it would be copy nobody asked for.
---
--- The key cap is the player's OWN binding, asked for by COMMAND rather than by
--- control -- client/loot.lua's fix, without which every prompt in the game said
--- E after a rebind.
--- @param show boolean
--- @param row table|nil
local function setPrompt(show, row)
    show = (show == true)
    candidate = show and row or nil
    if show == promptShown then return end
    promptShown = show

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = (S.signLabel or '%s for sale'):format(BR.ShopSolve.nameOf(row)),
        hint  = tostring(math.floor(tonumber(row.price) or 0)),
        key   = BR.Native.keyLabelForCommand('brinteract', 51),
        ring  = false,
    })
end

--- The point on the front of a car where its plate hangs.
---
--- READ OFF THE MODEL rather than hardcoded, so a Sanchez and a Bison both wear
--- theirs at their own bumper. GetModelDimensions is a model-table lookup and
--- this runs every frame the plate is up, so the answer is cached per model --
--- client/dui.lua's drawOnEntity caches its own for the same reason.
--- @param veh integer
--- @return number x
--- @return number y
--- @return number z
local function signPoint(veh)
    local model = GetEntityModel(veh)
    local d = DIMS[model]
    if not d then
        local a, b = GetModelDimensions(model)
        if not a or not b then return nil end
        d = { front = b.y, top = b.z }
        DIMS[model] = d
    end
    local v = GetOffsetFromEntityInWorldCoords(
        veh, 0.0, d.front + (tonumber(S.signForwardM) or 0.4),
        tonumber(S.signLift) or 1.15)
    return v.x, v.y, v.z
end

--- Which car is the player standing at?
---
--- ON THE TICK BAND, NOT THE FRAME BAND. Walking speed is about two metres a
--- second and the reach is four; ten passes a second is already finer than the
--- question can change, and this walks the whole catalogue.
BR.Loop.register(BR.Loop.TICK, 'shop.prompt', function()
    if spent or not built or not wantScene() then setPrompt(false) return end

    local c = GetEntityCoords(PlayerPedId())
    local reach = tonumber(S.reachM) or 4.0
    local best, bestD = nil, reach

    for _, row in ipairs(rows) do
        local veh = cars[row.id]
        if veh and veh ~= 0 and isTrue(DoesEntityExist(veh)) then
            local d = BR.Dist(c.x, c.y, row.x, row.y)
            if d <= bestD then best, bestD = row, d end
        end
    end

    if not best then setPrompt(false) return end
    setPrompt(true, best)
end)

--- ...and drawing it, which has to be per frame: BR.Dui.drawWorld is a
--- DrawSprite and a sprite lasts exactly one frame. The TICK pass decides
--- WHETHER; this decides WHERE.
BR.Loop.register(BR.Loop.FRAME, 'shop.draw', function()
    if not promptShown or not candidate then return end
    local veh = cars[candidate.id]
    -- RE-CHECKED, because reading the coordinates of a dead handle throws -- and
    -- in a frame callback five of those cost the whole band.
    if not veh or veh == 0 or not isTrue(DoesEntityExist(veh)) then return end

    local x, y, z = signPoint(veh)
    if not x then return end
    BR.Dui.drawWorld(promptPage(), x, y, z, tonumber(S.signScale) or 1.6)
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

        -- THE SAME FUNCTION THE SHOWROOM CAR WAS DRESSED BY, over the same row.
        BR.Shop.dress(veh, row)

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
