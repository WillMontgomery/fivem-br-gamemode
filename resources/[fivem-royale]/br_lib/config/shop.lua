-- The warmup vehicle shop (#224): what is for sale, where it stands, and what
-- it costs.
--
-- Owner, 2026-08-29:
--
--   "We're going to build a pre-game shop in which players can purchase no more
--    than 1 vehicle during warmup. Purchases cannot be refunded. The vehicle
--    purchased should become an inventory item, which, when used, should spawn
--    the vehicle which they purchased with them in the driver's seat."
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE CATALOGUE IS THE SAFETY MECHANISM. IF YOU READ ONE PARAGRAPH, READ THIS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- These cars are bought with the player's SAVED VOLTS BALANCE -- the currency
-- earned across every match they have ever played -- and not with Volts found
-- during this one. That was the open question in #224, #219 and #222, and the
-- owner answered all three at once on 2026-08-29: THE SAVED BALANCE, because at
-- warmup a player's match-Volts are zero and the saved balance is the only pot
-- that exists.
--
-- THAT ANSWER CAME WITH A CONDITION, AND THE CONDITION IS THIS TABLE:
--
--     "A bought car must be transport, not an advantage."
--
-- The market this project was built around has one rule -- the currency is
-- earned and never bought, and nothing you buy changes how a fight goes -- and
-- spending a saved balance on something that lands IN the match is the first
-- thing that has ever come near it. What keeps the rule true is not a check
-- anywhere in the code. It is WHICH MODELS ARE WRITTEN DOWN HERE.
--
-- SO THE PERSON CHOOSING MODELS IS THE PERSON ENFORCING THE RULE. A fast car is
-- transport. A car that wins fights is not, and there is no line of Lua that can
-- tell the difference -- config/vehicles.lua can refuse a thing with a gun bolted
-- to it (and does; see below) but nothing can refuse a thing that is merely
-- better. Armour, ramming mass, bulletproof glass and a roll cage are all bought
-- advantages that no ban list names.
--
-- If a row here would let somebody who has played a hundred matches beat
-- somebody who has played one, the condition the funding of this feature rests
-- on has been broken by a config edit, quietly, and nothing will report it.
--
-- ═══ WHAT THE CODE *CAN* CHECK, AND DOES ═══
--
-- config/vehicles.lua is a list of vehicles the gamemode REFUSES -- anything
-- that flies or carries built-in weapons -- and every row here is put through
-- BR.Config.IsAllowedVehicle at load. A refused model is dropped from the
-- catalogue with a line on the console, because the alternative is a car that
-- stands in the showroom, wears a price, takes somebody's Volts and then cannot
-- be delivered -- and answer 3 below says a purchase is never refunded.
--
-- That check bounds what is LEGAL. It does not bound what is FAIR, and it must
-- never be mistaken for having done so.
--
-- ═══ THE OWNER'S OTHER THREE ANSWERS, 2026-08-29 ═══
--
--   2. PER-MODEL PRICE, in config. Not a flat 750 -- `price` is a field on
--      every row below and #224's "750 Volts" is a starting point rather than
--      the rule.
--
--   3. A VANISHED CAR GETS NOTHING. "Purchases cannot be refunded" is meant
--      literally, and it includes the known engine fault where server-created
--      vehicles occasionally disappear (citizenfx/fivem#2623, OPEN; see the
--      write-up above brcar in br_core/server/vehicles.lua, which #202 lives
--      with). There is no refund path and no retry path in this feature, by
--      instruction. What there IS is a console line at every step of a
--      delivery, so a car that never arrived can be told apart from a car that
--      arrived and vanished.
--
--   4. THE ITEM IS ORDINARY. It takes a normal inventory slot, it can be
--      dropped, and it is dropped at the player's feet if the bag is full when
--      the match starts.
--
-- ═══════════════════════════════════════════════════════════════════════════

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Shop = {
    enabled = true,

    -- ------------------------------------------------------------------
    -- THE CATALOGUE, AND WHY THIS TABLE IS EMPTY
    -- ------------------------------------------------------------------
    --
    -- WITH NO ROWS THE FEATURE IS INERT RATHER THAN BROKEN. This is
    -- BR.Config.Rescue.points' rule, applied a second time and for the same
    -- reason: the owner authors this data in game and it is not written yet.
    -- An empty catalogue produces a warmup with no shop in it -- no display
    -- cars, no plate, no prompt, and a purchase handler that refuses every
    -- request. Not an error, not a crash, and no hardcoded fallback row that
    -- would put a car nobody chose on the pad.
    --
    -- Owner, 2026-08-29: "I will give you vehicle models, coords, and headings
    -- when ready."
    --
    -- ═══ THE SHAPE OF A ROW ═══
    --
    --   {
    --     -- REQUIRED
    --     id      = 'sultan',      -- unique; the item is sold as `car_sultan`
    --     model   = 'sultan',      -- a GTA vehicle model, NOT in config/vehicles.lua's refused list
    --     price   = 750,           -- Volts, a positive whole number, per model
    --     x = 0.0, y = 0.0, z = 0.0,   -- where the display car STANDS
    --     heading = 0.0,           -- which way it faces
    --
    --     -- OPTIONAL
    --     label   = 'Sultan',      -- the "[model name]" the plate says; the
    --                              -- model string is used when this is absent
    --     vtype   = 'automobile',  -- the sync tree; see VEHICLE_TYPES in
    --                              -- br_core/server/vehicles.lua. Defaults to
    --                              -- 'automobile', which is right for every
    --                              -- car. `bike` for motorcycles.
    --     tokenScale = 0.1,        -- this car's dropped token, as a multiple
    --                              -- of the model's own size
    --
    --     -- THE APPEARANCE. Everything here is applied to BOTH the showroom
    --     -- car and the car that comes out of the item, by one function, so
    --     -- they cannot disagree. Leave a field out and the model's own
    --     -- default is used -- deliberately, and on both cars alike.
    --     appearance = {
    --       primary = 0, secondary = 0,   -- GTA colour indices
    --       pearl = 0, wheelColour = 0,
    --       interior = 0, dashboard = 0,
    --       livery = -1, roofLivery = -1,
    --       windowTint = -1,              -- 0 none .. 5 limo (engine's own scale)
    --       wheelType = -1,               -- 0 sport, 1 muscle, ... 7 bike
    --       dirt = 0.0,                   -- 0 clean .. 15 filthy
    --       plate = 'BR SHOP',            -- up to 8 characters
    --       plateIndex = 0,
    --       xenon = false, xenonColour = -1,
    --       -- MOD SLOT -> MOD INDEX. Slot numbers are GTA's own: 0 spoiler,
    --       -- 1 front bumper, 2 rear bumper, 3 skirt, 4 exhaust, 5 cage,
    --       -- 6 grille, 7 bonnet, 11 engine, 12 brakes, 13 transmission,
    --       -- 14 horn, 15 suspension, 16 armour, 23 wheels.
    --       --
    --       -- 16 IS ARMOUR AND ARMOUR IS AN ADVANTAGE. Read the header again
    --       -- before writing one; the same goes for 15, which changes how a
    --       -- car handles under fire.
    --       mods = { [11] = 3, [12] = 2, [23] = 5 },
    --       -- TOGGLE MODS: 18 turbo, 22 xenon headlights.
    --       toggles = { [18] = true },
    --       -- EXTRAS, by the model's own extra ids. `true` means the extra is
    --       -- ON, which is the opposite of what the engine's own native takes
    --       -- -- see BR.Shop.dress, which does the inversion once.
    --       extras = { [1] = true, [2] = false },
    --     },
    --   },
    --
    -- ═══ A COMPLETE, PASTEABLE EXAMPLE ═══
    --
    -- This is a real row, valid today, and it is COMMENTED OUT rather than
    -- shipped -- an example that ships is a car nobody chose standing on the
    -- pad at coordinates nobody surveyed.
    --
    --   {
    --     id = 'sultan', model = 'sultan', label = 'Sultan',
    --     price = 750, vtype = 'automobile',
    --     x = -1035.6, y = -2733.4, z = 20.2, heading = 328.0,
    --     appearance = {
    --       primary = 27, secondary = 27, pearl = 0, wheelColour = 0,
    --       windowTint = 1, wheelType = 0, dirt = 0.0,
    --       plate = 'BR SHOP', plateIndex = 0,
    --       mods = { [11] = 2, [12] = 2, [13] = 2, [23] = 4 },
    --       toggles = { [18] = true },
    --     },
    --   },
    --
    -- Coordinates come from /brcoords, which is what the 23 ambulance points
    -- were surveyed with -- a ped-standing position, so the z can be trusted
    -- and the heading is the way a vehicle put there should face.
    items = {},

    -- ------------------------------------------------------------------
    -- HOW MANY
    -- ------------------------------------------------------------------
    --
    -- Owner: "no more than 1 vehicle during warmup". A NUMBER rather than a
    -- boolean flag so the day that becomes two, this is the whole change.
    limit = 1,

    -- ------------------------------------------------------------------
    -- THE SHOWROOM
    -- ------------------------------------------------------------------
    --
    -- ═══ THE DISPLAY CARS ARE LOCAL AND NON-NETWORKED, AND THAT IS A DESIGN
    --     DECISION RATHER THAN A LIMITATION ═══
    --
    -- Every client builds its own copy of the showroom from this table, with
    -- client-side CreateVehicle(..., false, false) -- the same call and the same
    -- flags client/bus.lua uses for the Battle Bus. Nothing about them is
    -- shared, and nothing needs to be: they are frozen, invincible, locked
    -- scenery that nobody can enter, move, damage or take.
    --
    -- WHAT THAT BUYS, IN ORDER OF HOW MUCH IT MATTERS:
    --
    --   * `sv_entityLockdown relaxed` NEVER COMES INTO IT. Lockdown refuses
    --     client-created NETWORKED entities; a non-networked one is not a clone
    --     and is never validated. So the showroom needs no server spawn, no
    --     routing bucket and no relevancy.
    --   * citizenfx/fivem#2623 NEVER COMES INTO IT EITHER. The bug where
    --     server-created vehicles randomly disappear cannot touch an entity the
    --     server never made. The one car that IS server-made is the one the
    --     player paid for, and that is the one place the risk belongs.
    --   * ONE CAR PER CLIENT PER ROW rather than one entity for everybody
    --     means no ownership race and no migration, which is what
    --     client/rescue.lua spent two playtest rounds on.
    --
    -- Doors locked, invincible, position frozen -- owner's words, and all three
    -- are applied in br_core/client/shop.lua.
    lockedState = 2,   -- eVehicleLockState 2 = LOCKED: no players, no NPCs.
                       -- NOT 4 -- that is LOCKED_PLAYER_INSIDE and waits for an
                       -- entry that never happens. client/rescue.lua shipped 4
                       -- and drove the whole way unlocked.

    -- How far the player has to be from a display car for its plate to come up
    -- and the interact key to act on it, in metres.
    reachM = 4.0,

    -- ...and how far apart two display cars have to be before this number stops
    -- being able to tell them apart. Purely a console warning at load: two cars
    -- inside one reach radius means a press is a coin flip.
    minSpacingM = 6.0,

    -- THE PLATE. Owner: "draw DUIs on the front of the vehicles which says
    -- '[model name] for sale' and the price."
    --
    -- ONE BROWSER, WHICH IS THE RULE THIS PROJECT ALREADY RUNS ON. A DUI is a
    -- whole CEF instance; client/ambheal.lua's note is the standing decision --
    -- "One browser for every world prompt in the game" -- and the crate, the
    -- pump, the revive and the heal station all share `lootprompt`. The shop is
    -- the fifth consumer of that one page, not a sixth browser, and certainly
    -- not one browser per car on the pad.
    --
    -- THE COST, SAID PLAINLY: one plate is up at a time, on the car the press
    -- would act on. A player reads a price by walking to a car rather than by
    -- looking across the lot. If the owner wants every car wearing its price
    -- from a distance, that is a different mechanism (one texture holding every
    -- row, drawn per car through DrawSpritePoly's UVs) and it is not built here.
    signForwardM = 0.4,    -- metres in front of the bumper, so the plate does
                           -- not z-fight with the bodywork
    signLift     = 1.15,   -- metres above the car's origin
    signScale    = 1.6,    -- the same figure ambheal's plate uses

    -- ------------------------------------------------------------------
    -- UNPACKING THE ITEM
    -- ------------------------------------------------------------------
    --
    -- `useMs` IS WHAT MAKES A CONSUMABLE USABLE FROM THE INVENTORY AT ALL --
    -- server/inventory.lua refuses any consumable that does not declare one, and
    -- that refusal is deliberate (the CPR kit has no useMs and must not be
    -- usable by hand). A car token DOES want to be used by hand, so it has one.
    --
    -- A CHANNEL RATHER THAN AN INSTANT, and 3 seconds rather than 8: unpacking a
    -- car in the open is a commitment, the same way drinking a shield is, and
    -- the existing use machinery already cancels it on damage and on a slot
    -- switch. Nothing new had to be built for that.
    useMs = 3000,

    -- How far in front of the player the car is placed, in metres.
    --
    -- THE SAME NUMBER AND THE SAME REASON AS brcar's SPAWN_AHEAD_M: a vehicle
    -- created at a ped's own coordinates leaves the engine to resolve the
    -- intersection, and it resolves it by throwing one of the two.
    spawnAheadM = 5.0,

    -- ...and how long the buyer's client waits for the car it paid for to
    -- actually arrive, and then for control of it.
    --
    -- ONESYNC RELEVANCY IS NOT A PROBLEM HERE AND THAT IS WORTH SAYING. An empty
    -- vehicle is relevant within 424 units of a client's focus (see the long
    -- write-up in config/rescue.lua) and this one is created FIVE METRES from
    -- the only client that matters. There is no SetEntityDistanceCullingRadius
    -- here and there must not be one: the ambulance needed it because it is
    -- built 825m away, and the native is deprecated with a known teleport-home
    -- fault that a widened radius is exactly what triggers.
    adoptMs   = 5000,
    controlMs = 3000,

    -- ------------------------------------------------------------------
    -- THE DROPPED TOKEN
    -- ------------------------------------------------------------------
    --
    -- Owner: "when dropped the loot item should be that vehicle but as a prop
    -- and super small, like the same size as a weapon prop pickup. If that's not
    -- possible, use marker ID 34 instead."
    --
    -- ═══ IT IS TRIED, AND THE FALLBACK IS AUTOMATIC RATHER THAN A GUESS ═══
    --
    -- Loot props are built with CreateObjectNoOffset (client/loot.lua) and
    -- scaled with BR.Native.propScale, which renormalises the entity's matrix
    -- axes -- there is no SetEntityScale in GTA V, #166 established that, and
    -- the owner confirmed the matrix route RENDERS when a 2x crate started
    -- clipping into the ground (config/airdrop.lua).
    --
    -- WHAT IS NOT ESTABLISHED ANYWHERE IN THIS TREE is whether GTA's object
    -- natives will build a VEHICLE model at all. CREATE_OBJECT takes an object
    -- archetype and a car is a vehicle archetype; the honest answer from outside
    -- a running client is UNVERIFIED. So this is not decided here. The client
    -- asks for the car as a prop, and if the engine answers 0 the entry falls
    -- back to `tokenMarker` on the spot and says so once on the console.
    --
    -- Either way the token is COLLISION-FREE, exactly like every other loose
    -- floor item, so a shrunken car cannot leave a full-size invisible hull in
    -- the road -- a matrix scale never touches a collision box.
    tokenScale  = 0.1,
    tokenMarker = 34,   -- the owner's stated fallback, used only if the prop
                        -- cannot be created

    -- ------------------------------------------------------------------
    -- SOUND
    -- ------------------------------------------------------------------
    --
    -- THE EXISTING PICKUP CUE, NOT A NEW ONE. BR.Config.Loot.pickupSound is
    -- PICK_UP / HUD_FRONTEND_DEFAULT_SOUNDSET -- the sound that already fires
    -- whenever something lands in an inventory -- and config/audio.lua's rule is
    -- that two actions which sound identical are worse than one that sounds
    -- wrong. A purchase IS something landing in an inventory, so it is the same
    -- cue.
    --
    -- ═══ REACHED BY KEY, AND POINTED AT THE SAME TABLE RATHER THAN A COPY ═══
    --
    -- tools/verify.sh refuses a set/name pair written at a call site outside
    -- three files, and the reason is good: a pair nothing knows the key of
    -- cannot be auditioned with /brsfx, cannot be re-pointed with `brsfx bind`,
    -- and fails SILENTLY when the set is wrong. So the shop plays a cue KEY.
    --
    -- But a second set/name pair spelled out in config/audio.lua would be a
    -- second authored copy of one fact -- the day the owner re-points the pickup
    -- sound, the shop would keep the old one and nothing would say so. So
    -- `register` below installs the cue as THE SAME TABLE
    -- (BR.Config.Loot.pickupSound), not a copy of its two strings. One authored
    -- pair, auditionable as `/brsfx shop.buy`.
    cue = 'shop.buy',

    -- ------------------------------------------------------------------
    -- THE WORDING, WHICH IS THE OWNER'S AND IS NOT TO BE EDITED
    -- ------------------------------------------------------------------
    --
    -- Every player-facing string this feature produces is here, and there are
    -- exactly three of them. Two are quoted verbatim from the owner and the
    -- third is a number. NOTHING ELSE IS SPOKEN: no hints, no empty-state copy,
    -- no "you cannot afford this" of our own invention (the market's existing
    -- sentence is reused), no explanation of what the item does.
    boughtToast = 'Thanks for your purchase. It will be available in your '
               .. 'inventory once the match starts.',
    -- The plate. `%s` is the model name; the price is the second line and is
    -- rendered as a bare number, which is how every other Volts figure in this
    -- game is written.
    signLabel = '%s for sale',
}

--- Is this model one config/vehicles.lua refuses?
---
--- HERE RATHER THAN IN EACH CALLER, because BOTH ends resolve the catalogue --
--- the server to arbitrate purchases, the client to build the showroom -- and
--- two copies of "is this car legal" is exactly the pair that comes apart. A
--- model the client thinks is sellable and the server does not is a plate on a
--- car nobody can buy; the other way round is worse.
---
--- CALLED, NEVER RUN AT LOAD. GetHashKey is a native and BR.Config.IsAllowedVehicle
--- lives in a sibling config file loaded by the same glob, so neither is
--- reachable while this file is being read. Same reason client/ambheal.lua
--- resolves its model set on first use.
--- @param model string
--- @return string|nil why   nil when the model is fine
function BR.Config.Shop.refusedReason(model)
    if not BR.Config.IsAllowedVehicle then return nil end
    local ok, hash = pcall(GetHashKey, model)
    if not ok then return 'model name could not be hashed' end
    local allowed, why = BR.Config.IsAllowedVehicle(hash)
    if allowed then return nil end
    return why or 'refused'
end

--- REGISTERED RATHER THAN APPENDED, AND CALLED RATHER THAN RUN AT LOAD.
---
--- Each catalogue row becomes an ordinary CONSUMABLE in
--- BR.Config.ConsumableById. That is the airdrop-shelf pattern config/loot.lua
--- uses for the CPR kit, for the same reason: the item has to be carried,
--- dropped, labelled, propped and used like any other, but it must be in NO
--- rarity bucket, so that no crate on the map can ever roll a car.
---
--- ═══ WHY THIS IS A FUNCTION AND NOT JUST A LOOP AT THE BOTTOM OF THIS FILE ═══
---
--- config/loot.lua builds `BR.Config.ConsumableById` with a plain assignment:
---
---     BR.Config.ConsumableById = {}
---
--- so anything registered BEFORE that line is destroyed by it. br_lib's
--- fxmanifest loads `config/*.lua` as a GLOB, and the order in which a glob is
--- expanded is a property of the platform's resource loader rather than
--- something this file can see -- `shop` sorts after `loot`, which is almost
--- certainly enough, and "almost certainly" is how silent half-wiring gets
--- shipped here. So the registration is a function, and br_core's client and
--- server shop files each call it once at their own load, by which time every
--- br_lib script is up whatever order they ran in.
---
--- IDEMPOTENT, so two callers cost one registration.
--- @param refusedReason fun(model:string):string|nil
--- @return table rows      the usable catalogue
--- @return table rejects   rows that were thrown out, with reasons
function BR.Config.Shop.register(refusedReason)
    local S = BR.Config.Shop
    local rows, rejects = BR.ShopSolve.catalogue(S, refusedReason)

    BR.Config.ConsumableById = BR.Config.ConsumableById or {}

    for i = 1, #rows do
        local row = rows[i]
        local id  = BR.ShopSolve.itemIdFor(row)
        BR.Config.ConsumableById[id] = {
            id     = id,
            label  = BR.ShopSolve.nameOf(row),
            -- `plural` IS THE NAME A REFUSAL USES (#171), and it exists here so
            -- the fallback -- label .. 's' -- never has to be right about a
            -- vehicle name. It is the same word: you cannot hold two.
            plural = BR.ShopSolve.nameOf(row),
            rarity = BR.Rarity and BR.Rarity.LEGENDARY or nil,
            kind   = BR.ItemKind and BR.ItemKind.CONSUMABLE or 'consumable',
            -- CARRY ONE, STACK ONE. One purchase is one car, and a pocket of
            -- three would be three cars off one payment.
            maxStack = 1, carryMax = 1,
            useMs    = tonumber(S.useMs) or 3000,
            -- THE GROUND PROP IS THE CAR ITSELF, at a fraction of its size --
            -- see `tokenScale` above for what is and is not established about
            -- that, and for the marker fallback when it does not work.
            prop      = row.model,
            propScale = BR.ShopSolve.tokenScale(row, S),
            -- ...AND WHAT TO DRAW IF THE ENGINE WILL NOT BUILD THAT PROP. The
            -- owner's own fallback, read by client/loot.lua at the moment a
            -- prop fails rather than decided here -- see `tokenMarker`.
            fallbackMarker = tonumber(S.tokenMarker) or 34,
            -- WHAT MAKES THIS A CAR RATHER THAN A POTION, and the only field
            -- server/inventory.lua's use pass looks for. Its VALUE is the
            -- catalogue id, so the item knows which row built it and the
            -- delivered car is dressed from that row and from nothing else.
            shopCar   = row.id,
        }
    end

    -- ═══ AND THE CUE, AS A REFERENCE RATHER THAN A COPY ═══
    --
    -- `= BR.Config.Loot.pickupSound`, not `= { set = ..., name = ... }`. The
    -- same table, so there is one authored pair and re-pointing the pickup
    -- sound re-points this with it. Same shape as BR.Config.AmbHeal.stretcher(),
    -- which IS BR.Config.Rescue.stretcher for the same reason.
    --
    -- HERE RATHER THAN IN config/audio.lua because this is where the DECISION
    -- lives -- "the shop reuses the pickup sound" is a fact about the shop --
    -- and because doing it at call time needs no load order between two config
    -- files that otherwise have none.
    if S.cue and BR.Config.Audio and BR.Config.Audio.cues
       and BR.Config.Loot and BR.Config.Loot.pickupSound then
        BR.Config.Audio.cues[S.cue] = BR.Config.Loot.pickupSound
    end

    S.rows = rows
    return rows, rejects
end
