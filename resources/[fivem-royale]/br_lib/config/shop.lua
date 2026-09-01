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
    -- WHAT "RANDOM COLOURS" DRAWS FROM
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-31: "can you make the vehicles in the shop spawn with
    -- random colors each time they are spawned? except the ambulance. that one
    -- has a livery so color won't matter."
    --
    -- ═══ THIS IS A CURATED SET AND NOT THE FULL RANGE, AND HE WAS RIGHT TO
    --     OFFER TO PICK ONE ═══
    --
    -- He said he would choose a set if the full range looked bad. IT WOULD HAVE
    -- LOOKED BAD, and the reason is a fact about GTA's palette rather than a
    -- matter of taste. The paint index space is 0..159 (Cfx game reference,
    -- "Vehicle Colors"), and it is not a spread of colours -- it is a parts
    -- catalogue:
    --
    --   0..26    TWENTY-SEVEN GREYS. Metallic, Matte, Util and Worn blacks,
    --            silvers and gunmetals, several of which are indistinguishable
    --            from one another at ten paces. That is a sixth of the range
    --            before a single colour appears, so a uniform draw over 0..159
    --            paints roughly one car in six grey and one in three something
    --            no player would call a colour.
    --   Util/Worn EVERYWHERE ELSE (43..48, 56..60, 75..81, 85..87, 108..110,
    --            113..116, 121..124, 126, 130, 132..133). These are the service
    --            and weathered finishes -- flat, chalky, deliberately unlovely.
    --            A showroom car in "Worn Sea Wash" reads as an unpainted car
    --            rather than as a colour somebody chose.
    --   88..116  A LONG RUN OF BROWNS, BEIGES AND SANDS -- Pueblo Beige, Moss
    --            Brown, Beechwood, Sun Bleeched Sand -- which are hard to tell
    --            apart on a car and harder still across a lot.
    --   117..120,
    --   156..159 CHROME, BRUSHED STEEL, PURE GOLD, BRUSHED GOLD, DEFAULT ALLOY.
    --            Chrome and gold read as a cheat rather than a paint job, and
    --            "Default Alloy" is not a colour at all.
    --
    -- So the roll draws from the METALLIC families instead: the glossy finishes,
    -- spread deliberately across the hue circle, with black and white kept as
    -- anchors because a showroom with no black car in it looks wrong too.
    -- THIRTY-TWO ENTRIES, which is enough that thirteen cars rarely repeat and
    -- few enough that every one of them is a colour a player would name.
    --
    -- ═══ AND IT IS HIS TO EDIT, WHICH IS THE WHOLE REASON IT IS HERE ═══
    --
    -- Nothing in this list is his. It is a first cut, exactly like the prices
    -- above the catalogue, and this is the ONE place a paint index is written
    -- down -- BR.ShopSolve.paint takes the table, so adding, removing or
    -- reordering entries is the whole change. An empty table turns the roll off
    -- and every car goes back to the colour authored on its row.
    --
    -- Names are the game's own, from the Cfx vehicle-colour reference.
    palette = {
        0,    -- Metallic Black
        4,    -- Metallic Silver
        11,   -- Metallic Anthracite Grey
        27,   -- Metallic Red
        28,   -- Metallic Torino Red
        29,   -- Metallic Formula Red
        35,   -- Metallic Candy Red
        36,   -- Metallic Sunrise Orange
        37,   -- Metallic Classic Gold
        38,   -- Metallic Orange
        50,   -- Metallic Racing Green
        51,   -- Metallic Sea Green
        53,   -- Metallic Green
        61,   -- Metallic Midnight Blue
        64,   -- Metallic Blue
        67,   -- Metallic Diamond Blue
        70,   -- Metallic Bright Blue
        71,   -- Metallic Purple Blue
        73,   -- Metallic Ultra Blue
        88,   -- Metallic Taxi Yellow
        89,   -- Metallic Race Yellow
        90,   -- Metallic Bronze
        91,   -- Metallic Yellow Bird
        92,   -- Metallic Lime
        111,  -- Metallic White
        112,  -- Metallic Frost White
        135,  -- Hot Pink
        137,  -- Metallic Vermillion Pink
        144,  -- Hunter Green
        145,  -- Metallic Purple
        150,  -- Metallic Lava Red
        157,  -- Epsilon Blue
    },

    -- ------------------------------------------------------------------
    -- THE CATALOGUE, AS THE OWNER SURVEYED IT ON 2026-08-29
    -- ------------------------------------------------------------------
    --
    -- Thirteen cars, and every model, coordinate and heading below is HIS,
    -- transcribed from his survey without adjustment. This table shipped empty
    -- until he authored it; the "inert rather than broken" behaviour that
    -- covered that is still in BR.ShopSolve.enabled and still correct if the
    -- rows are ever removed.
    --
    -- ═══ TWELVE OF THESE THIRTEEN CARS NO LONGER WEAR THE COLOUR ON THEIR ROW
    --     (owner, 2026-08-31) ═══
    --
    -- "can you make the vehicles in the shop spawn with random colors each time
    --  they are spawned? except the ambulance. that one has a livery so color
    --  won't matter."
    --
    -- So `primary` and `secondary` below stopped being what the showroom paints
    -- with. Every row except `ambulance` draws from `palette` above instead --
    -- one colour per row per match, derived from the server's seed by
    -- BR.ShopSolve.paint, and applied identically to the display car and to the
    -- car that comes out of the item.
    --
    -- ═══ THE NUMBERS ARE KEPT, AND NEITHER REASON IS SENTIMENT ═══
    --
    --   1. `ambulance` STILL READS ITS ROW. It carries `randomColour = false`
    --      and it is painted from the table exactly as it always was -- colour
    --      AND livery -- so the minus-one conversion below is live code on a
    --      shipped row and still has to be right.
    --   2. THEY ARE THE FALLBACK FOR EVERY ROW. BR.ShopSolve.appearance takes a
    --      SEED; with no seed -- a br_core restart mid-match, a client that
    --      never got an answer, an emptied `palette` -- it hands back exactly
    --      what is written here. A car in the colour he surveyed is a far better
    --      failure than a car in whatever the engine felt like.
    --
    -- AND THEY ARE THE RECORD. These were HIS numbers, transcribed from his
    -- survey, and the double-entry block at the top of tools/test_shop.lua still
    -- checks this table against them. Deleting them would delete the only proof
    -- that the conversion below was ever applied correctly.
    --
    -- ═══ HIS SURVEY NUMBERS ARE ONE-BASED. THIS CONFIG IS ZERO-BASED. ═══
    --
    -- READ THIS BEFORE YOU "FIX" A COLOUR. He surveyed the paint in a menu and
    -- wrote down the row he clicked, and the menu counts from one:
    --
    --   Owner, 2026-08-29: "It's the menu's row number (1st entry = GTA index 0)."
    --
    -- Every `primary`/`secondary` below is therefore HIS NUMBER MINUS ONE, and
    -- the same conversion is applied to `livery`:
    --
    --     his note            this file
    --     ----------------    ---------------
    --     Preset Color 1      primary = 0
    --     Preset Color 2      primary = 1
    --     Preset Color 4      primary = 3
    --     Preset Color 5      primary = 4
    --     Preset Color 6      primary = 5
    --     Preset Color 7      primary = 6
    --     Livery 5            livery  = 4
    --
    -- His original note is quoted verbatim on each row, so the two can always be
    -- checked against each other. IF THE AMBULANCE OR A FALLBACK CAR COMES OUT
    -- THE WRONG COLOUR THE BUG IS ONE OF THESE SUBTRACTIONS, NOT THE CONVENTION
    -- -- do not "correct" the table back to his row numbers, or all thirteen
    -- shift by one. (A car that is merely a colour nobody authored is not that
    -- bug at all: that is the roll working, and `palette` is where it lives.)
    --
    -- ═══ THE FAIRNESS CONSTRAINT: REVIEWED, RAISED, AND ACCEPTED ═══
    --
    -- The header of this file says the catalogue is what keeps "a bought car
    -- must be transport, not an advantage" true, and that this list is where the
    -- rule is enforced or broken. THIS LIST WAS CHECKED AGAINST THAT RULE AND
    -- THE OWNER OVERRODE IT, KNOWINGLY. He was told, by name, that:
    --
    --     voltic2     has a rocket boost
    --     riot        is armoured
    --     mesa3       is armoured
    --     marshall    drives over other cars
    --     formula2    is the fastest thing in the game
    --
    -- -- i.e. that several of these rows are bought advantages rather than
    -- transport, which is the condition he set when he agreed the cars could be
    -- paid for out of the saved balance. His answer, 2026-08-29:
    --
    --     "Ship all 13 -- I know what they are."
    --
    -- So this is a decision on the record and not an oversight. IT IS WRITTEN
    -- DOWN HERE SO THAT NOBODY LATER READS THE HEADER, LOOKS AT `voltic2`, AND
    -- CONCLUDES THAT THE RULE WAS SIMPLY MISSED. It was not missed. It was
    -- raised, and it was overruled by the person whose rule it is.
    --
    -- ═══ THE PRICES ARE A FIRST PASS, PROPOSED, AND HIS TO TUNE ═══
    --
    -- He asked for a tier to be proposed and said he would adjust it: "propose a
    -- tier and I'll adjust." NONE OF THESE NUMBERS IS HIS. They are a first cut
    -- that sorts the catalogue by what a car actually does -- novelty and cheap
    -- mobility at the bottom, armour and the two 1500s at the top -- and
    -- `mesa3` sits at 750 because that is the one figure #224 named. Every one
    -- of them is meant to be edited.
    --
    -- ═══ WHY EVERY ROW AUTHORS BOTH COLOURS ═══
    --
    -- He gave ONE colour per car. Both `primary` and `secondary` are written
    -- with it anyway, and that is not padding.
    --
    -- IT IS ALSO THE CONVENTION THE ROLL FOLLOWS. BR.ShopSolve.appearance paints
    -- both coats with ONE rolled index for exactly the reason below: a car with
    -- two different colours on it is a paint job, and he asked for a colour.
    --
    -- A -1 in this table means "leave it", and BR.Shop.dress honours that by
    -- READING the value off the vehicle it is dressing. For a freshly created
    -- vehicle the value it reads is the RANDOM colour combination the engine
    -- just rolled -- so an unwritten `secondary` is not a default, it is a
    -- different random number on the showroom car and on the car that comes out
    -- of the item. That is precisely the drift "exactly as shown when they
    -- purchased it" cannot have, and it is invisible until somebody notices
    -- their car has the wrong trim forty minutes into a match.
    --
    -- `pearl` and `wheelColour` are rolled in the same combination and are
    -- written for the same reason. 0 IS A DETERMINISM PLACEHOLDER AND NOT A
    -- TASTE DECISION -- he did not specify them, and any fixed number beats a
    -- random one. If he wants a different trim, these are the fields.
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
    --     randomColour = false,    -- pin this car to the colour authored below
    --                              -- instead of rolling one out of `palette`.
    --                              -- The ambulance, and nothing else. Absent
    --                              -- means the car IS rolled.
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
    -- The x, y and heading come from /brcoords, which is what the 23 ambulance
    -- points were surveyed with -- and the heading it prints is the way a
    -- vehicle put there should face.
    --
    -- ═══ THE `z` IS A SETTLED CAR'S ORIGIN, NOT A HEIGHT SOMEBODY STOOD AT ═══
    --
    -- READ THIS BEFORE "CORRECTING" A z, AND BEFORE WRITING ANY CODE THAT
    -- PLACES A CAR FROM ONE. This block said the opposite until 2026-08-31 --
    -- "a ped-standing position, so the z can be trusted", "the height of that
    -- person's feet" -- and that sentence is why the un-settled fallback in
    -- br_core/client/shop.lua was built backwards and stayed backwards for two
    -- rounds. It subtracted half a metre from the number and then handed it to
    -- SET_ENTITY_COORDS, which takes z as where the BOTTOM of the entity goes
    -- and lifts the car by its own height to put it there. A ped height,
    -- lowered, then raised by a whole car: the floating, computed.
    --
    -- THE NUMBERS THEMSELVES SETTLE WHICH IT IS. The twelve rows on the apron
    -- stand in a line, in x order, across 45m of flat airfield -- and their z
    -- swings 0.84m over that line without ever being monotonic in x. That is
    -- not a surface. Sort them by z instead and the tall bodies are at the top
    -- (marshall 4.30, a monster truck, a clear 0.28 above anything else; then
    -- outlaw 4.02, mesa3 3.99, caracara2 3.93, every one of them a raised
    -- off-roader) and the low ones at the bottom (drifttampa 3.59, formula2
    -- 3.46, an open-wheel car). Thirteen origin-to-wheel distances over one
    -- surface, which is exactly what a person walking the line COULD NOT have
    -- produced: their feet would have given one number thirteen times. (The
    -- veto is not part of that comparison -- it stands 150m up the runway from
    -- the others, on its own patch of ground.)
    --
    -- SO A CAR THE ENGINE REFUSES TO SETTLE BELONGS AT EXACTLY THIS NUMBER,
    -- with nothing added and nothing taken off, placed with
    -- SET_ENTITY_COORDS_NO_OFFSET. That is what the client now does, and it
    -- says so on the console every time it has to.
    --
    -- HIS x AND y ARE EXACT AND MUST NEVER BE TOUCHED -- "those coords are very
    -- specifically placed. Don't change them" -- and the z is not to be
    -- re-typed either. On a healthy build nothing here decides a height at all:
    -- SetVehicleOnGroundProperly computes the origin-to-wheel distance from the
    -- model's own wheels and puts the car on the real surface, which is more
    -- accurate than any surveyed figure can be. A car that ends up a few
    -- centimetres off one of these numbers is that native working. Re-surveying
    -- the z to match what you see puts the guess back in front of it.
    --
    -- ═══ EVERY ROW CARRIES A `label`, AND EVERY ONE IS ROCKSTAR'S OWN WORD ═══
    --
    -- The plate reads "<name> for sale". Without a `label` that name is the
    -- MODEL STRING -- "drifttampa for sale", "caracara2 for sale" -- which is
    -- what shipped first, because inventing display copy is exactly what this
    -- project's standing rule forbids.
    --
    -- Owner, 2026-08-29: "the vehicle names on the DUI should be their proper
    -- names, not the model names. These are publicly documented if you don't
    -- have them." THAT IS WHAT MAKES THESE ALLOWED. They are not invented text
    -- and they are not our preference; they are the strings the game itself
    -- displays, so the plate now says what a player would read anywhere else.
    --
    -- SOURCE, FOR ALL THIRTEEN: the game's own vehicles.meta and GXT text
    -- labels, as dumped in DurtyFree/gta-v-data-dumps `vehicles.json` -- keyed
    -- by the exact model string, giving ManufacturerDisplayName.English and
    -- DisplayName.English. Manufacturer + name, in that order, is the form the
    -- game uses. Each was read out of that dump directly rather than from a
    -- wiki, because the variants are the whole difficulty here:
    --
    --     formula2   is "Ocelot R88" and NOT "Formula 2" -- and the pairing is
    --                inverted from the guess: `formula` is the Progen PR4.
    --     voltic2    is "Rocket Voltic", not "Voltic".
    --     caracara2  is "Caracara 4x4"; plain `caracara` is "Caracara".
    --     veto       is "Veto Classic"; `veto2` is "Veto Modern".
    --     riot       is "Police Riot"; `riot2` is a different vehicle, the RCV.
    --
    -- TWO OF THEM ARE JUDGEMENT CALLS AND HE SHOULD KNOW WHICH:
    --
    --   `mesa3` -- the game gives ALL THREE Mesas the same GXT label, `mesa`
    --     -> "Mesa", so the armoured Merryweather variant has NO distinct
    --     Rockstar name. "Canis Mesa" is therefore the true one. Vehicle sites
    --     write "Canis Mesa (Merryweather)" to disambiguate, but that
    --     parenthetical is theirs, not the game's, so it is not used here.
    --
    --   `sanchez` -- the game's label is literally "Sanchez (livery)" (GXT
    --     SANCHEZ01), with `sanchez2` holding the plain "Sanchez". The
    --     "(livery)" is a data-file disambiguator rather than a name anybody
    --     reads, so the plate says "Maibatsu Sanchez".
    --
    -- `ambulance` and `riot` carry NO manufacturer in the game files, so they
    -- are the bare "Ambulance" and "Police Riot". GTA Wiki attributes both to
    -- Brute from in-game badging; that is not a Rockstar string and is not used.
    --
    -- ═══ THE ORDER IS HIS SURVEY ORDER ═══
    --
    -- Not sorted by price or by position. Two cars at exactly equal distance
    -- resolve to the one written FIRST (BR.ShopSolve.nearest), so the row order
    -- is a tie-break rule as well as a reading order, and his order is the one
    -- that matches the notes he will check this against.
    items = {
        -- `veto` WAS A TYPO AFTER ALL, AND THE NOTE THAT SAID OTHERWISE IS KEPT
        -- HERE BECAUSE BEING WRONG TWICE IN THE SAME PLACE IS WORTH RECORDING.
        --
        -- It shipped at x 4665.97 where every other car sits between 4468 and
        -- 4512. That was queried as a possible transposed digit and he answered
        -- on 2026-08-29: "No those coords are very specifically placed. Don't
        -- change them." So it was written down as a deliberate outlier.
        --
        -- IT WAS NOT. He re-surveyed the spot on 2026-08-31 by standing on it --
        -- "Veto goes here 4466.08, -4479.03, 4.22" -- after reporting for three
        -- rounds that the veto "still isn't spawning". It always spawned; it sat
        -- 154m up the runway where nobody looked, and 2026-08-30's /brshop
        -- readout showed why nobody could see it either: ground there probes at
        -- 4.18 against an authored z of 3.3, so it was created a metre under.
        --
        -- WHAT THIS COST, so the lesson is legible: three playtest rounds, a
        -- whole investigation into why one car of thirteen would not settle, and
        -- a fallback rewritten around the wrong story. The tell was in the data
        -- the entire time -- twelve cars between z 3.46 and 4.30 on one flat
        -- apron, and a thirteenth 154m away claiming a z from that same range.
        -- A confirmation from the owner is evidence, not proof; the ground under
        -- the point is proof, and it disagreed from the first readout onward.
        --
        -- The heading is UNCHANGED at 198.1 -- he gave three numbers, not four,
        -- and 198.1 is within a degree of every other row's facing.
        {
            id = 'veto', model = 'veto', label = 'Dinka Veto Classic',
            price = 250,
            x = 4466.08, y = -4479.03, z = 4.22, heading = 198.1,
            appearance = {  -- his note: Preset Color 1
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
            },
        },
        {
            -- THE ONE MOTORCYCLE IN THE CATALOGUE, so the one row that needs a
            -- `vtype`. It picks the sync tree the server builds when the item is
            -- unpacked and it is NOT checked against the model -- an `automobile`
            -- tree under a bike is the kind of mismatch that desyncs quietly.
            id = 'sanchez', model = 'sanchez', label = 'Maibatsu Sanchez',
            price = 350, vtype = 'bike',
            x = 4468.09, y = -4478.40, z = 3.68, heading = 197.7,
            appearance = {  -- his note: Preset Color 6
                primary = 5, secondary = 5, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'outlaw', model = 'outlaw', label = 'Nagasaki Outlaw',
            price = 500,
            x = 4471.23, y = -4477.56, z = 4.02, heading = 199.8,
            appearance = {  -- his note: Preset Color 4
                primary = 3, secondary = 3, pearl = 0, wheelColour = 0,
            },
        },
        {
            -- 750 IS #224's OWN NUMBER, kept on the row the issue described.
            id = 'mesa3', model = 'mesa3', label = 'Canis Mesa',
            price = 750,
            x = 4474.67, y = -4477.09, z = 3.99, heading = 199.3,
            appearance = {  -- his note: Preset Color 2
                primary = 1, secondary = 1, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'caracara2', model = 'caracara2', label = 'Vapid Caracara 4x4',
            price = 750,
            x = 4478.54, y = -4476.13, z = 3.93, heading = 199.8,
            appearance = {  -- his note: Preset Color 4
                primary = 3, secondary = 3, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'nightshade', model = 'nightshade', label = 'Imponte Nightshade',
            price = 600,
            x = 4481.98, y = -4474.05, z = 3.63, heading = 201.4,
            appearance = {  -- his note: Preset Color 1
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'infernus', model = 'infernus', label = 'Pegassi Infernus',
            price = 900,
            x = 4485.30, y = -4472.56, z = 3.73, heading = 200.8,
            appearance = {  -- his note: Preset Color 7
                primary = 6, secondary = 6, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'drifttampa', model = 'drifttampa', label = 'Declasse Drift Tampa',
            price = 600,
            x = 4492.41, y = -4470.39, z = 3.59, heading = 199.8,
            appearance = {  -- his note: Preset Color 1
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'voltic2', model = 'voltic2', label = 'Coil Rocket Voltic',
            price = 1500,
            x = 4495.90, y = -4468.74, z = 3.78, heading = 201.9,
            appearance = {  -- his note: Preset Color 1
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'formula2', model = 'formula2', label = 'Ocelot R88',
            price = 1500,
            x = 4499.17, y = -4467.59, z = 3.46, heading = 201.0,
            appearance = {  -- his note: Preset Color 1
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
            },
        },
        {
            -- ═══ THE ONE CAR THE ROLL DOES NOT TOUCH, AND HE GAVE THE REASON
            --     ═══
            --
            -- Owner, 2026-08-31: "except the ambulance. that one has a livery so
            -- color won't matter."
            --
            -- So this row keeps everything below it: his Preset Color 1, and his
            -- Livery 5. It is the only row in the catalogue whose `primary` is
            -- still what a player sees on the pad.
            --
            -- `marshall` CARRIES A LIVERY TOO AND IS *NOT* EXEMPT, which is
            -- worth saying because it looks like an oversight and is not. He
            -- named one car. A marshall's flag sits on its flanks over painted
            -- bodywork, so colour reads on it perfectly well; an ambulance's
            -- livery is the vehicle. If he wants the marshall pinned as well,
            -- this line is the whole change.
            id = 'ambulance', model = 'ambulance', label = 'Ambulance',
            price = 500, randomColour = false,
            x = 4503.87, y = -4468.23, z = 3.89, heading = 198.4,
            appearance = {  -- his notes: Preset Color 1, Livery 5
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
                -- HIS "Livery 5", THROUGH THE SAME MINUS-ONE AS THE COLOURS. He
                -- read it off a one-based menu row; SetVehicleLivery counts
                -- from zero.
                livery = 4,
            },
        },
        {
            id = 'riot', model = 'riot', label = 'Police Riot',
            price = 1250,
            x = 4507.97, y = -4465.96, z = 3.85, heading = 200.3,
            appearance = {  -- his note: Preset Color 1
                primary = 0, secondary = 0, pearl = 0, wheelColour = 0,
            },
        },
        {
            id = 'marshall', model = 'marshall', label = 'Cheval Marshall',
            price = 1250,
            x = 4512.49, y = -4463.92, z = 4.30, heading = 198.7,
            appearance = {  -- his notes: Preset Color 5, Livery American Flag
                primary = 4, secondary = 4, pearl = 0, wheelColour = 0,
                -- ═══ UNVERIFIED. THIS ONE NUMBER IS A RESEARCHED GUESS. ═══
                --
                -- He wrote a NAME here rather than a menu row -- "Livery
                -- American Flag" -- so the minus-one convention has nothing to
                -- subtract from and the index had to be looked up.
                --
                -- WHAT IS ESTABLISHED: the marshall carries 25 flag liveries,
                -- one per country, drawn from `flag_sign_1`..`flag_sign_25` in
                -- marshall.ytd (GTAMods Wiki, Carvariations.ymt; GTA Wiki,
                -- "Marshall"). So the valid indices are 0..24 and an American
                -- flag is certainly among them.
                --
                -- WHAT IS NOT ESTABLISHED: the ORDER. The only ordered list
                -- found is the GTA Wiki's country list, in which "United States
                -- of America" is the 24th of 25 entries -- which by his own
                -- one-based convention gives index 23, written below. That list
                -- is a wiki's prose, NOT a datamined livery order, and it is
                -- internally suspect: it runs Japan before Jamaica, so it is
                -- neither reliably alphabetical nor demonstrably the game's own
                -- index order. No carvariations dump confirming the order was
                -- found.
                --
                -- SO HE SHOULD CHECK IT, AND IT COSTS HIM ONE GLANCE. The
                -- marshall stands at the end of the line in the showroom wearing
                -- whatever this index is. If the flag is not the Stars and
                -- Stripes, count the American Flag's row in the same menu he
                -- surveyed from, subtract one, and put that here.
                --
                -- IF THIS INDEX IS OUT OF RANGE the native is ignored and the
                -- car keeps the RANDOM livery the engine rolled -- which means
                -- the showroom marshall and the delivered marshall would wear
                -- different flags. That is the loud failure and it is the one to
                -- watch for.
                livery = 23,  -- unverified: see above
            },
        },
    },

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

    -- ------------------------------------------------------------------
    -- REACH, AND WHY IT NO LONGER PICKS THE CAR
    -- ------------------------------------------------------------------
    --
    -- ═══ AT THE SURVEYED SPACING, NO RADIUS CAN TELL TWO CARS APART ═══
    --
    -- The owner's showroom (2026-08-29) stands its cars in a line with the
    -- tightest pair -- `sanchez` and `outlaw` -- 3.25m apart, and nine other
    -- pairs inside 4.5m. The midpoint between two cars 3.25m apart is 1.63m from
    -- each of them, so a reach that put ONE of them in range and not the other
    -- would have to be under 1.63m: a radius that ends inside both cars' own
    -- bodywork and that nobody could stand in. There is no value of this number
    -- that makes "in reach" mean "the one car I am at".
    --
    -- So it stopped being asked to. BR.ShopSolve.nearest resolves the plate and
    -- the purchase to the NEAREST car in reach, and `reachM` now answers only
    -- one question: am I at the showroom at all? Two cars in range is the normal
    -- case on this pad and is no longer ambiguous.
    --
    -- ═══ WHICH IS WHY THIS WENT UP RATHER THAN DOWN ═══
    --
    -- 4.0 was chosen when a smaller radius still bought disambiguation. It
    -- cannot, and 4.0 was too small for the catalogue that arrived: the plate
    -- hangs off the front of the MODEL (see `signForwardM`, which reads
    -- GetModelDimensions), so on the longest cars here -- `marshall`, `riot`,
    -- `ambulance` -- it sits roughly three and a half metres in front of the
    -- car's own origin. A player who walks up to that plate to read it is
    -- four-and-a-half to five metres from the origin the reach is measured from,
    -- and at 4.0 the plate blinked out exactly where he stopped to read it.
    --
    -- 5.0 clears the biggest model in the catalogue with room to stand, and
    -- costs nothing anywhere else: a wider radius can only ever add FURTHER cars
    -- to the candidate set, and a further car never wins a nearest.
    reachM = 5.0,

    -- ...and the load-time warning, which now means something else.
    --
    -- ═══ 6.0 WAS A COIN-FLIP THRESHOLD AND IT FIRED ON TEN PAIRS ═══
    --
    -- This used to be "closer together than the reach radius", i.e. "a press
    -- between them is a coin flip". Against the surveyed pad that was true of
    -- TEN OF THE SEVENTY-EIGHT PAIRS and printed ten yellow lines at every
    -- boot -- a warning about the showroom being a showroom. Nearest-wins made
    -- the statement false as well as noisy.
    --
    -- ═══ 3.0 IS A PHYSICAL FACT INSTEAD ═══
    --
    -- Below three metres, two parked cars are not close together, they are
    -- INSIDE ONE ANOTHER: a `riot` is about 2.6m wide and a `marshall` about
    -- 3.4m, so two of anything car-shaped whose origins are under 3m apart have
    -- overlapping bodywork and certainly no gap for a player to stand in and
    -- read a plate. That is a defect in the coordinates, it is not something
    -- nearest-wins can rescue, and it is worth a line on the console.
    --
    -- Against his thirteen rows it fires on NOTHING, which is the point of
    -- picking it: the tightest real pair is 3.25m, so there are 25cm of headroom
    -- and the next line printed will be about a row that deserves one.
    minSpacingM = 3.0,

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

    -- ═══ HOW WIDE THE SIGN IS, IN METRES -- WHICH IS A NEW UNIT HERE ═══
    --
    -- Owner, 2026-08-30: "The store DUIs are dynamically sized and face the
    -- player. I want them to be stationary, with the DUI displayed on the front
    -- face of the vehicle, akin to a yard sign... The overall DUI size is good."
    --
    -- `signScale` USED TO LIVE HERE AND IT IS GONE, because it was not a size.
    -- It was the multiplier on BR.Dui.drawWorld's SCREEN fraction: a billboard
    -- pinned to a world point but measured in display width, which is both
    -- halves of what he is complaining about -- it squared itself to the camera
    -- (that is what SetDrawOrigin + DrawSprite IS) and it held a constant share
    -- of the screen however far away he stood. BR.Dui.drawFace draws a quad in
    -- the world instead, so the number that describes it has to be metres.
    --
    -- ═══ 0.75 IS "THE OVERALL DUI SIZE IS GOOD", CONVERTED ═══
    --
    -- The old plate was 0.09 x 1.6 = 0.144 of the screen's width. At the game's
    -- default field of view a 16:9 screen spans about 79 degrees, so the world
    -- width the screen covers at distance d is roughly 1.66 x d metres, and the
    -- plate occupied 0.144 of that: about 0.72m across at three metres, which is
    -- the distance somebody stands at to read a price off a car.
    --
    -- SO THE SIZE HE APPROVED IS PRESERVED AT ONE DISTANCE AND ONLY ONE, and
    -- that is not a defect -- it is the instruction. A fixed sign is smaller
    -- from across the lot and bigger up close, which is what every real object
    -- does and what "stationary" asks for.
    --
    -- 0.75m x 0.375m, because the page is 512x256 and the height follows the
    -- texture's own aspect rather than being a second number to keep in step.
    -- That is a yard sign, which is the shape he named.
    --
    -- THE INTERFACE-SIZE PREFERENCE STILL MULTIPLIES IT (BR.Dui.drawFace applies
    -- `prefs.ui` exactly as drawWorld did), so a player at 1.30 gets a sign 30%
    -- wider. It is the one scaling left, and it is the player's.
    signWidthM = 0.75,

    -- ═══ HOW HIGH THE PLATE HANGS -- DERIVED, WITH ONE NUDGE ═══
    --
    -- Owner, 2026-08-29: "change the DUI to draw at the elevation of the
    -- vehicle's bumper."
    --
    -- `signLift` USED TO BE 1.15 AND USED TO MEAN "metres above the car's
    -- origin", which is the whole of why it had to change: it was one height for
    -- thirteen models that range from a `sanchez` to a `marshall`, so it could
    -- only ever be right for the middle of them. The height comes off
    -- GetModelDimensions now (BR.ShopSolve.signHeight), and these two numbers
    -- are the shape of that derivation rather than the answer to it.
    --
    -- `signBumperFrac` IS WHERE THE BUMPER SITS IN THE MODEL'S OWN HEIGHT, with
    -- 0 the ground the tyres stand on and 1 the roof. 0.35 puts it low on the
    -- body: about 0.42m off the ground on an `infernus`, about 1.1m on a
    -- `marshall`, which is the whole point of expressing it as a fraction.
    --
    -- ONE NUMBER RATHER THAN THIRTEEN. A per-row height would be exact and would
    -- also be thirteen more things to tune every time a car is added; if a
    -- single model ever needs its own, that is a row field and an argument for
    -- adding one, not a reason to abandon the derivation for the other twelve.
    signBumperFrac = 0.35,
    signLift     = 0.0,    -- metres added on top, to nudge every plate at once

    -- ------------------------------------------------------------------
    -- HOW FAR THE SHOWROOM CARS START BELOW THEIR SURVEYED HEIGHT
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-30 (#243): "After seeing the shop once in warmup, and going
    -- outside its focus area (cell/culling radius), then coming back, all the
    -- vehicles are floating off the ground again at waist level." And then, on
    -- what to do about it: "The prop pickup should be lowered by maybe 0.5m and
    -- the same is true for the vehicles. That's all we need."
    --
    -- ═══ IT IS SUBTRACTED FROM THE STARTING HEIGHT, NOT FROM HIS SURVEY ═══
    --
    -- "those coords are very specifically placed. Don't change them" still
    -- holds, and the rows above are untouched. This is applied at
    -- CreateVehicle, on top of the authored `z`, which config/shop.lua has
    -- always described as a STARTING height rather than a final one.
    --
    -- ═══ AND IT DELIBERATELY LOSES TO THE GROUNDING, WHICH IS THE POINT ═══
    --
    -- br_core/client/shop.lua calls SetVehicleOnGroundProperly a few lines after
    -- the create and before the freeze. When that native succeeds it puts the
    -- car's wheels on the surface and this number stops mattering: the car has
    -- been told where the ground is, and 0.5m either side of the start makes no
    -- difference to where it lands. So ON FIRST SPAWN THIS PROBABLY CHANGES
    -- NOTHING VISIBLE, and that is the correct behaviour rather than a defect --
    -- a drop applied AFTER a successful grounding would bury every car half a
    -- metre into the pad, which is the one outcome nobody asked for.
    --
    -- WHERE IT DOES SHOW is exactly where he is complaining: whatever puts a
    -- streamed-back car at waist height is not the grounding, because the
    -- grounding ran once, before the freeze, and a frozen entity is not
    -- re-settled. The height it comes back at is derived from where the car was
    -- CREATED, and this lowers that.
    --
    -- SO IT IS A DIAL AND NOT A DERIVATION. "maybe 0.5m" is his estimate and he
    -- will want to nudge it after seeing it; that is the whole reason it is a
    -- named value here rather than a literal in the client. If the cars come
    -- back correct but sit low on first spawn, the grounding is not succeeding
    -- and the console says so on the line below it.
    groundDropM = 0.5,

    -- How long one showroom car will wait for the ground under it to arrive
    -- before it is placed anyway, in milliseconds.
    --
    -- ═══ "THIS WILL HAPPEN TO PLAYERS IF THEY COME BACK TO WARMUP AFTER A
    --     PREVIOUS MATCH" (owner, 2026-08-31) ═══
    --
    -- THE PAD IS BUILT OFF THE STATE FLIP TO WARMUP, and at that instant the
    -- player is still in the lobby, 1.36km from the airfield, with no collision
    -- resident under any of the thirteen rows. SET_VEHICLE_ON_GROUND_PROPERLY
    -- needs ground to put wheels on; with none it refuses, and a refusal is a
    -- car standing at a height nobody measured. That is the floating.
    --
    -- SO IT IS A RACE, AND THE READOUTS SHOW BOTH SIDES OF IT: `settled at
    -- build 12/13` on a cold first build, `0/13` on a rebuild. Nothing in
    -- br_core/client/shop.lua ever waited for streaming, so which side of the
    -- race a player landed on was decided by how far away they happened to be.
    --
    -- THE SAME NUMBER AND THE SAME ARGUMENT AS config/loot.lua's
    -- `collisionWaitMs`, which has held crates out of the physics simulation
    -- until their roof arrived since 2026-08-23. 1500ms IS A CEILING AND NOT A
    -- COST: the wait ends the moment the collision reports in, which for a
    -- player already standing on the pad is the first check. Only the build
    -- that fires from across the island pays anything, and it pays it once.
    --
    -- WHEN IT EXPIRES THE CAR IS PLACED ANYWAY, at the surveyed z. A car that
    -- behaves exactly as it did before this existed beats a showroom that never
    -- finishes appearing because one streaming request never completed.
    collisionWaitMs = 1500,

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
    -- ═══ 0.1 -> 0.5 -> 0.375, AND HIS ORIGINAL SPEC IS SUPERSEDED RATHER THAN
    --     CONTRADICTED ═══
    --
    -- The quote above -- "super small, like the same size as a weapon prop
    -- pickup" -- is what he asked for BEFORE seeing one on the ground. Having
    -- seen it, 2026-08-29: "when dropped, the item prop should be 5x the size",
    -- which took 0.1 to 0.5. Having seen THAT, later the same day: "please make
    -- the vehicle prop pickups 75% the current size. The ones that spawn when
    -- dropping a vehicle."
    --
    -- 75% OF WHAT IS SHIPPED, NOT OF THE ORIGINAL: 0.5 x 0.75 = 0.375. The
    -- earlier quote is kept above because it is still the reason the marker
    -- fallback exists at all.
    tokenScale  = 0.375,

    -- ------------------------------------------------------------------
    -- HOW FAR THE DROPPED TOKEN SITS BELOW WHERE IT SETTLED
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-30 (#240): "At rest, the vehicle pickup props are floating
    -- above the ground at waist-level." And, on what to do: "The prop pickup
    -- should be lowered by maybe 0.5m and the same is true for the vehicles.
    -- That's all we need."
    --
    -- SUBTRACTED FROM THE HEIGHT PlaceObjectOnGroundProperly ARRIVED AT, in
    -- br_core/client/loot.lua, and remembered as the entry's resting height so
    -- the hover animation rises from and returns to the lowered figure rather
    -- than putting the float back every time somebody walks past.
    --
    -- ═══ IT IS ON THE CAR TOKEN AND ON NOTHING ELSE, WHICH IS THE WHOLE
    --     REASON IT LIVES HERE AND NOT IN config/loot.lua ═══
    --
    -- The same settle puts ~1300 rifles, bandages and ammo boxes on the ground
    -- across the map, and they are not floating -- he has never said they are.
    -- A global 0.5m drop would bury every one of them. So this rides on the
    -- catalogue entry, next to `propScale`, and reaches exactly the items this
    -- config creates.
    --
    -- HE WILL WANT TO NUDGE IT. "maybe 0.5m" is an estimate made by eye, which
    -- is why it is a named value rather than a literal at the draw site -- and
    -- why it is a SEPARATE number from `groundDropM` above even though both are
    -- 0.5 today. A shrunken car prop and a full-size showroom car are not the
    -- same object and there is no reason their corrections must match.
    tokenDropM = 0.5,

    -- ═══ THE FALLBACK MARKER: 34 WAS A HELICOPTER ═══
    --
    -- Owner, 2026-08-30: "When I drop the marshall why does it use a 3dmarker
    -- instead of the model of the prop? It's also a helicopter marker, not a
    -- vehicle...." And: "Also the marker 34 issue, yeah. That should be marker
    -- 36."
    --
    -- 34 WAS HIS OWN NUMBER, taken on trust when he first named it -- "if that's
    -- not possible, use marker ID 34 instead" -- and this file said at the time
    -- that "nothing in this tree claims to know what marker 34 draws". He has
    -- now read one off his own screen: it is MarkerTypeHelicopterSymbol. 36 is
    -- MarkerTypeCarSymbol, the next-but-one entry in the same run of vehicle
    -- glyphs (33 plane, 34 helicopter, 35 boat, 36 car, 37 motorcycle), and it
    -- is the one he asked for.
    --
    -- ONE MARKER FOR THE WHOLE CATALOGUE, INCLUDING THE BIKE. `sanchez` is a
    -- motorcycle and would read more exactly as 37, and that is not worth a
    -- per-row field: he asked for "a vehicle" rather than for the right vehicle,
    -- the fallback is what a player sees only when the prop could not be built,
    -- and a car glyph says "there is a vehicle in this box" for all thirteen.
    tokenMarker = 36,

    -- ...AND HOW BIG THAT FALLBACK MARKER IS DRAWN, IN METRES.
    --
    -- ═══ A DIFFERENT KNOB FROM `tokenScale`, IN DIFFERENT UNITS ═══
    --
    -- The two are NOT the same knob. `tokenScale` is a multiple of the model's
    -- own size and only reaches a car the engine agreed to build as a PROP. This
    -- is a radius in metres and is what gets drawn when it did not.
    --
    -- ═══ AND WHICH ONE IS LIVE IS NO LONGER AN OPEN QUESTION ═══
    --
    -- This file used to argue at length that the prop path probably did not work
    -- at all -- CREATE_OBJECT takes an OBJECT archetype, a car is a VEHICLE
    -- archetype -- and that `tokenScale` was therefore likely inert. OBSERVATION
    -- HAS ANSWERED IT, and the answer is BOTH. On 2026-08-30 the owner reported,
    -- in one sitting, dropped car tokens that are PROPS ("the vehicle pickup
    -- props are floating above the ground at waist-level" -- a marker cannot
    -- float, it is drawn at a ground height every frame) and one model,
    -- `marshall`, that fell back to the marker instead.
    --
    -- SO THE ENGINE BUILDS MOST OF THEM AND REFUSES AT LEAST ONE, and both knobs
    -- are live -- `tokenScale` for the twelve, this one for whatever the engine
    -- turns down. WHY `marshall` SPECIFICALLY IS REFUSED IS NOT ESTABLISHED and
    -- is not guessed at here; client/loot.lua names the entry and the reason on
    -- the console, once, and that line is what will settle it.
    --
    -- ═══ WHICH IS WHY THEY STILL MOVE TOGETHER WHEN HE RESIZES THE PICKUP ═══
    --
    -- Owner, 2026-08-29: "please make the vehicle prop pickups 75% the current
    -- size." Applied to both, 0.5 x 0.75 = 0.375 -- and now that both paths are
    -- known to be live, keeping them in step is not a hedge but a requirement:
    -- the marshall's token and the caracara2's are the same thing to a player
    -- and must not be different sizes.
    tokenMarkerScale = 0.375,

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
    -- exactly four of them. Three are quoted verbatim from the owner and the
    -- fourth is a number. NOTHING ELSE IS SPOKEN: no hints, no empty-state copy,
    -- no "you cannot afford this" of our own invention (the market's existing
    -- sentence is reused), no explanation of what the item does.
    boughtToast = 'Thanks for your purchase. It will be available in your '
               .. 'inventory once the match starts.',

    -- ...AND THE ONE REFUSAL THIS FEATURE IS ALLOWED TO SPEAK.
    --
    -- Owner, 2026-08-31: "let's make sure the player cannot use their purchased
    -- vehicle spawn while already inside another vehicle. They can only use it
    -- while on foot. If they try to use it while not on foot, issue a toast
    -- stating 'You can only spawn a vehicle while on foot.'"
    --
    -- HIS SENTENCE, INCLUDING THE FULL STOP, and it is the ONLY thing said about
    -- this rule anywhere. No prompt hint, no greyed slot, no second wording for
    -- the mid-use cancel -- server/inventory.lua raises this same string on both
    -- of its two arms, because a player who gets into a car halfway through the
    -- three-second use is being refused for the identical reason and being told
    -- so twice differently would read as two rules.
    --
    -- IT IS A REFUSAL AND NOT A HINT, which is why server/shop.lua's rule about
    -- silent failures does not cover it: that rule is about the engine losing a
    -- car somebody paid for, where there is nothing true to say. This one is a
    -- thing the player did and can undo by stepping out.
    onFootToast = 'You can only spawn a vehicle while on foot.',

    -- ...AND THE SECOND SENTENCE OF THE SAME TOAST (#239).
    --
    -- Owner, 2026-08-30: "'Thank you for your purchase.' toast should also
    -- include a note about their new balance, stated as 'Your new balance is:
    -- [X] Volts.'"
    --
    -- HIS WORDING, INCLUDING THE COLON AND THE FULL STOP. `[X] Volts` is his
    -- placeholder for the figure and the currency word together, which is
    -- exactly what BR.ShopSolve.priceLine already builds -- so there is ONE
    -- `%s` here rather than a `%d` and a second `%s`. That matters: a two-slot
    -- template would put the space between the number and the word in this
    -- string as well as in priceLine, and the two would drift the day the
    -- currency is renamed.
    --
    -- THE WORD ITSELF IS NOT IN THIS STRING. config/market.lua's `currency` is
    -- the one place it is spelled, and it reaches the slot through priceLine.
    -- Writing "Volts" here would make it three places, counting Ringmaster's
    -- constant, and the third is the one nobody greps.
    --
    -- AND IT IS ONE TOAST, NOT TWO. He said the purchase toast "should ALSO
    -- include" the balance, so the two sentences are joined with a space and
    -- shown together; a second notification would stack on the first and push
    -- it off the top of the list.
    balanceToast = 'Your new balance is: %s.',
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
            -- see `tokenScale` above. The engine builds most of these and has
            -- been observed refusing at least one (`marshall`), which is what
            -- the marker fallback below is for.
            prop      = row.model,
            propScale = BR.ShopSolve.tokenScale(row, S),
            -- ...AND HOW FAR TO LOWER IT ONCE IT HAS SETTLED. Owner: "The prop
            -- pickup should be lowered by maybe 0.5m." On the ITEM rather than
            -- on the loot config, because the same settle puts every rifle and
            -- bandage on the map down and none of those is floating -- see
            -- `tokenDropM`.
            propDrop  = tonumber(S.tokenDropM) or 0.0,
            -- ...AND WHAT TO DRAW IF THE ENGINE WILL NOT BUILD THAT PROP. Read
            -- by client/loot.lua at the moment a prop fails rather than decided
            -- here -- see `tokenMarker`, which is a car glyph since the owner
            -- read the old 34 off his screen as a helicopter.
            fallbackMarker = tonumber(S.tokenMarker) or 36,
            -- ...AND HOW BIG TO DRAW IT. See `tokenMarkerScale`: metres, not a
            -- multiple of the model, so it is a different knob from `propScale`
            -- and neither reaches the other's case.
            fallbackMarkerScale = tonumber(S.tokenMarkerScale) or 0.5,
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
