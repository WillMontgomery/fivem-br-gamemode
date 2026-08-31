-- Unit tests for the warmup vehicle shop (#224).
--
-- ═══ THE FIXTURE IS THE POINT, AND THE SHIPPED CATALOGUE IS EMPTY ═══
--
-- BR.Config.Shop.items ships as `{}` on purpose -- the owner authors the models,
-- coordinates and headings in game and has not written them yet, and until he
-- does the feature must be INERT rather than broken (BR.Config.Rescue.points'
-- rule, applied a second time). So EVERY behavioural test below runs against a
-- FIXTURE catalogue built in this file. Testing against the shipped table would
-- assert nothing at all, and would start passing for the wrong reason the moment
-- he pastes his rows in.
--
-- Exactly one test reads the shipped table, and it asserts that it is empty.
--
-- ═══ WHAT THIS SUITE IS FOR ═══
--
-- Three of this feature's rules are effectively unobservable in a running game
-- and expensive to get wrong:
--
--   "EXACTLY AS SHOWN WHEN THEY PURCHASED IT". The wrong implementation looks
--   identical to the right one for as long as nobody happens to notice that the
--   car that came out of the item is a different colour from the one in the
--   showroom -- and by then the display entity has been gone for forty minutes
--   and there is nothing left to compare against. The property that makes it
--   true is structural (one function, one row, nothing on the wire) and this
--   file asserts the structure.
--
--   THE DELIVERY ORDERING. The item is handed out one line after
--   BR.Inv.clearFor(m) in match.onEnter(BUS). One line EARLIER and the wipe
--   deletes the thing the player paid for -- and the symptom is a purchase that
--   silently never arrives, which is indistinguishable from the purchase having
--   failed.
--
--   NO REFUND, EVER. Owner, answer 3: a purchase is not refunded, including when
--   the engine loses the car. The failure mode of getting that wrong is a
--   SECOND CAR FOR ONE PAYMENT, and it only shows up under an engine fault
--   nobody can reproduce on demand (citizenfx/fivem#2623).

local RES  = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'

local fakeTime = 0
function GetGameTimer() return fakeTime end

-- ---------------------------------------------------------------------------
-- Natives and engine stubs
-- ---------------------------------------------------------------------------

--- ═══ THE REAL JENKINS HASH, NOT A COUNTER ═══
---
--- This used to hand out `0x10000001`, `0x10000002`... to every model except
--- `lazer`, which was pinned to its real hash so that ONE refusal was genuine.
--- That was fine while the shipped catalogue was empty. It stopped being fine
--- the moment thirteen real models landed in it: "none of the owner's thirteen
--- cars is on the refused list" is the assertion that matters most in this file,
--- and against invented hashes it could not fail. It would have agreed with the
--- catalogue no matter what was in it -- including `hydra`.
---
--- So the stub computes GTA's actual `joaat` (lowercased, 32-bit), and the
--- refusal check below is the shipped refused table run against the shipped
--- model names with the hashes the engine itself would produce.
--- @param s string
--- @return integer
function GetHashKey(s)
    s = tostring(s or ''):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

local handlers = {}
function AddEventHandler(name, fn) handlers[name] = fn end
function RegisterNetEvent() end
function GetCurrentResourceName() return 'br_core' end

--- Everything the server told a client, in order.
local sent = {}
function TriggerClientEvent(name, src, payload)
    sent[#sent + 1] = { name = name, src = src, payload = payload }
end

--- Server-side ped reads. One player, standing at the origin facing north.
local peds = {}
function GetPlayerPed(src) return peds[src] and peds[src].ped or 0 end
function GetEntityCoords(ped)
    for _, p in pairs(peds) do
        if p.ped == ped then return { x = p.x, y = p.y, z = p.z } end
    end
    return { x = 0.0, y = 0.0, z = 0.0 }
end
function GetEntityHeading(ped)
    for _, p in pairs(peds) do
        if p.ped == ped then return p.heading end
    end
    return 0.0
end

local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',        -- BR.Dist and BR.NormHash
    'config/overrides.lua',
    'config/match.lua',
    'config/loot.lua',       -- BR.Config.ConsumableById and the pickup cue
    'config/audio.lua',      -- BR.Config.Audio.cues, which the shop cue lands in
    'config/vehicles.lua',   -- the refused list the catalogue is checked against
    'shared/shop_solve.lua',
    -- THE CURRENCY'S NAME, which the plate's price line now reads. Loaded here
    -- rather than stubbed so the assertion about what the plate says is made
    -- against the shipped string and not against a copy of it.
    'config/market.lua',
    'config/shop.lua',
}) do load(f) end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        print('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function readFile(p)
    local fh = io.open(p)
    if not fh then return '' end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ---------------------------------------------------------------------------
describe("the shipped catalogue -- the owner's survey of 2026-08-29")
-- ---------------------------------------------------------------------------

--- ═══ HIS SURVEY, RETYPED FROM HIS MESSAGE AND NOT FROM THE CONFIG ═══
---
--- This is DOUBLE ENTRY and it is the whole point of the block below. These
--- numbers were typed out of the owner's own note; config/shop.lua was written
--- from the same note independently. A transcription slip in either one -- a
--- transposed digit, a colour off by one, a heading on the wrong row -- makes
--- the two disagree and fails a test. Copying these values out of the config
--- would assert nothing whatsoever.
---
--- `preset` IS HIS NUMBER, ONE-BASED, EXACTLY AS HE WROTE IT ("Preset Color 6").
--- The minus-one to GTA's zero-based index is applied HERE, in the assertion,
--- so the conversion itself is what is under test and not just its output.
---
---   model, x, y, z, heading, his Preset Color row, his livery index (or nil)
local SURVEY = {
    { 'veto',       4665.97, -4478.9,  3.30, 198.1, 1 },
    { 'sanchez',    4468.09, -4478.40, 3.68, 197.7, 6 },
    { 'outlaw',     4471.23, -4477.56, 4.02, 199.8, 4 },
    { 'mesa3',      4474.67, -4477.09, 3.99, 199.3, 2 },
    { 'caracara2',  4478.54, -4476.13, 3.93, 199.8, 4 },
    { 'nightshade', 4481.98, -4474.05, 3.63, 201.4, 1 },
    { 'infernus',   4485.30, -4472.56, 3.73, 200.8, 7 },
    { 'drifttampa', 4492.41, -4470.39, 3.59, 199.8, 1 },
    { 'voltic2',    4495.90, -4468.74, 3.78, 201.9, 1 },
    { 'formula2',   4499.17, -4467.59, 3.46, 201.0, 1 },
    -- "Livery 5" on his note, which is row five and therefore index four.
    { 'ambulance',  4503.87, -4468.23, 3.89, 198.4, 1, 4 },
    { 'riot',       4507.97, -4465.96, 3.85, 200.3, 1 },
    -- "Livery American Flag" is a NAME, not a row, so the minus-one has nothing
    -- to subtract from. 23 is a researched, UNVERIFIED index; see the long note
    -- on the row in config/shop.lua. Pinned here so it cannot drift silently --
    -- when he corrects it, this number moves with it.
    { 'marshall',   4512.49, -4463.92, 4.30, 198.7, 5, 23 },
}

--- His prices, as proposed to him and as he has yet to tune them.
local PRICES = {
    veto = 250, sanchez = 350, outlaw = 500, ambulance = 500,
    nightshade = 600, drifttampa = 600, mesa3 = 750, caracara2 = 750,
    infernus = 900, riot = 1250, marshall = 1250, voltic2 = 1500,
    formula2 = 1500,
}

do
    -- ═══ THE HASH STUB IS THE REAL ONE, PROVED AGAINST THE SHIPPED TABLE ═══
    --
    -- Every refusal assertion in this file rests on GetHashKey being GTA's
    -- joaat rather than a counter. Four hashes authored in config/vehicles.lua
    -- by hand are re-derived here from their model names; if the stub were
    -- fake, all four would miss.
    ok(GetHashKey('lazer') == 0xB39B0AE6 and GetHashKey('titan') == 0x761E2AD3
           and GetHashKey('hydra') == 0x39D6E83F
           and GetHashKey('blimp') == 0xF7004C86,
        'the hash stub reproduces four hashes the refused table authored by '
            .. 'hand -- so a refusal in this file is the real table refusing a '
            .. 'real model')

    local items = BR.Config.Shop.items
    ok(type(items) == 'table' and #items == #SURVEY,
        'ships his thirteen cars', #items)

    ok(BR.ShopSolve.enabled(BR.Config.Shop) == true,
        'so the shop exists -- there is a showroom, a plate and a purchase')

    -- ═══ NOT ONE OF THE THIRTEEN IS REFUSED ═══
    --
    -- The catalogue is put through BR.Config.IsAllowedVehicle at load and a
    -- refused model is DROPPED -- which would be a car he surveyed, priced and
    -- expects to see, silently missing from the pad. Zero rejects is the
    -- assertion; thirteen survivors is the same fact from the other side.
    local rows, rejects = BR.ShopSolve.catalogue(BR.Config.Shop,
                                                 BR.Config.Shop.refusedReason)
    ok(#rejects == 0,
        'and NOT ONE of them is on the refused-vehicle list -- nothing he '
            .. 'surveyed is dropped from the pad',
        #rejects > 0 and rejects[1].id .. ': ' .. rejects[1].why or nil)
    ok(#rows == #SURVEY,
        'so all thirteen survive the load', #rows)

    -- ═══ EVERY ROW, AGAINST HIS NOTE ═══
    for _, s in ipairs(SURVEY) do
        local model, x, y, z, heading, preset, livery = table.unpack(s)
        local row = BR.ShopSolve.rowById(rows, model)

        ok(row ~= nil, model .. ' is on the pad')
        if row then
            ok(row.model == model and row.id == model,
                model .. ': the catalogue id and the model are his one word')

            -- HIS COORDINATES, TO THE DIGIT. He confirmed on 2026-08-29 that
            -- they are deliberate -- "those coords are very specifically
            -- placed. Don't change them" -- including `veto`, which stands
            -- 154m from the other twelve.
            ok(row.x == x and row.y == y and row.z == z,
                model .. ': stands exactly where he surveyed it',
                ('%s,%s,%s'):format(row.x, row.y, row.z))
            ok(row.heading == heading,
                model .. ': faces the way he surveyed it', row.heading)

            ok(row.price == PRICES[model],
                model .. ': carries the proposed price', row.price)

            local a = BR.ShopSolve.appearance(row)

            -- ═══ THE MINUS-ONE, WHICH IS THE THING MOST LIKELY TO BE
            --     "CORRECTED" BACK ═══
            ok(a.primary == preset - 1,
                ('%s: his Preset Color %d is paint index %d'):format(
                    model, preset, preset - 1), a.primary)

            -- BOTH COLOURS AUTHORED. An unwritten `secondary` is not a
            -- default -- BR.Shop.dress reads it off the vehicle, and a freshly
            -- created vehicle carries the engine's RANDOM colour. That is a
            -- different answer on the showroom car and on the delivered one,
            -- which is exactly what "exactly as shown when they purchased it"
            -- forbids.
            ok(a.secondary == a.primary and a.pearl >= 0 and a.wheelColour >= 0,
                model .. ': every colour in the combination is authored, so '
                    .. 'none of them is left to the engine to randomise')

            if livery then
                ok(a.livery == livery,
                    ('%s: livery index %d'):format(model, livery), a.livery)
            end
        end
    end

    ok(BR.ShopSolve.rowById(rows, 'sanchez').vtype == 'bike',
        'the one motorcycle declares the bike sync tree; nothing else needs to')

    -- ═══ THE PRICES SPAN A REAL TIER ═══
    local lo, hi = math.huge, 0
    for _, r in ipairs(rows) do
        lo = math.min(lo, r.price)
        hi = math.max(hi, r.price)
        ok(r.price > 0 and r.price == math.floor(r.price), r.id ..
            ': the price is a positive whole number of Volts', r.price)
    end
    ok(lo == 250 and hi == 1500,
        'and they run from 250 to 1500 rather than being one flat number')
end

-- ---------------------------------------------------------------------------
describe("the plates say Rockstar's names, not the model strings")
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-29: "the vehicle names on the DUI should be their proper
-- names, not the model names. These are publicly documented if you don't have
-- them."
--
-- ═══ WHY THIS IS A TABLE OF THIRTEEN LITERALS AND NOT A RULE ═══
--
-- There is no transformation from `drifttampa` to "Declasse Drift Tampa" -- the
-- names come out of the game's own vehicles.meta and GXT labels, and half of
-- them are actively counterintuitive. So the assertion is a second copy typed
-- from the source dump, and its whole job is to fail when somebody "tidies" one
-- of the surprising ones into the obvious wrong answer.
--
-- The five that are commonly got wrong are commented, because a bare table of
-- names does not tell the next reader which entries are load-bearing.
local NAMES = {
    veto       = 'Dinka Veto Classic',   -- NOT "Veto"; `veto2` is Veto Modern
    sanchez    = 'Maibatsu Sanchez',
    outlaw     = 'Nagasaki Outlaw',
    mesa3      = 'Canis Mesa',           -- the game gives all three Mesas one label
    caracara2  = 'Vapid Caracara 4x4',   -- NOT "Caracara"; that is `caracara`
    nightshade = 'Imponte Nightshade',
    infernus   = 'Pegassi Infernus',
    drifttampa = 'Declasse Drift Tampa',
    voltic2    = 'Coil Rocket Voltic',   -- NOT "Voltic"; that is `voltic`
    formula2   = 'Ocelot R88',           -- NOT "Formula 2"; `formula` is the PR4
    ambulance  = 'Ambulance',            -- no manufacturer in the game files
    riot       = 'Police Riot',          -- NOT "Riot"; `riot2` is the RCV
    marshall   = 'Cheval Marshall',
}

do
    -- REGISTERED HERE, ON THE SHIPPED CATALOGUE. Everything after the fixture is
    -- installed runs against three invented cars; this block is about his
    -- thirteen, so it registers them itself. register() is idempotent and is the
    -- real function br_core calls at load -- so the inventory items asserted
    -- below are built the way the game builds them.
    local rows = BR.Config.Shop.register(BR.Config.Shop.refusedReason)
    for _, s in ipairs(SURVEY) do
        local model = s[1]
        local row = BR.ShopSolve.rowById(rows, model)
        ok(row ~= nil and BR.ShopSolve.nameOf(row) == NAMES[model],
            ('%s sells as "%s"'):format(model, NAMES[model]),
            row and BR.ShopSolve.nameOf(row) or 'no row')
    end

    -- ═══ AND NOT ONE PLATE STILL SHOWS A SPAWN CODE ═══
    --
    -- BR.ShopSolve.nameOf falls back to the MODEL STRING when a row has no
    -- label, which is what shipped first and is what the owner was looking at
    -- when he asked for this. A row that lost its label would quietly go back
    -- to "drifttampa for sale" and every per-name assertion above would still
    -- have to be edited to hide it; this one cannot be satisfied that way.
    local bare = {}
    for _, r in ipairs(rows) do
        if BR.ShopSolve.nameOf(r) == r.model then bare[#bare + 1] = r.id end
    end
    ok(#bare == 0,
        'no plate falls back to the spawn code -- every row carries a label',
        table.concat(bare, ', '))

    -- THE ITEM IN THE INVENTORY IS NAMED THE SAME WAY, so the car in the bag
    -- and the car on the pad are one thing to a player rather than two.
    local reg = BR.Config.ConsumableById['car_formula2']
    ok(reg ~= nil and reg.label == 'Ocelot R88' and reg.plural == 'Ocelot R88',
        'and the inventory item wears the same name as the plate',
        reg and reg.label or 'unregistered')
end

-- ---------------------------------------------------------------------------
describe('the dropped token, and which knob actually reaches it')
-- ---------------------------------------------------------------------------
do
    -- ═══ TWO INSTRUCTIONS ON ONE DAY, APPLIED IN ORDER ═══
    --
    -- Owner, 2026-08-29: "when dropped, the item prop should be 5x the size"
    -- took it 0.1 -> 0.5. Later the same day, having seen that: "please make the
    -- vehicle prop pickups 75%% the current size" -- 75%% of what SHIPS, so
    -- 0.5 x 0.75 = 0.375. His earlier "super small, like the same size as a
    -- weapon prop pickup" is superseded rather than contradicted.
    ok(BR.Config.Shop.tokenScale == 0.375,
        'the car token is three quarters of what it was', BR.Config.Shop.tokenScale)

    local reg = BR.Config.ConsumableById['car_marshall']
    ok(reg ~= nil and reg.propScale == 0.375,
        'and that reaches the registered item rather than stopping at config',
        reg and reg.propScale or 'unregistered')

    -- ═══ THE OTHER KNOB, AND BOTH OF THEM ARE LIVE ═══
    --
    -- This file used to say the prop path was "probably" dead -- CREATE_OBJECT
    -- takes an OBJECT archetype and a car is a VEHICLE archetype -- and that
    -- `propScale` was therefore inert. OBSERVATION HAS ANSWERED IT, and the
    -- answer is both. On 2026-08-30 the owner reported, in one sitting, dropped
    -- car tokens that are PROPS ("the vehicle pickup props are floating above
    -- the ground at waist-level" -- a marker is drawn at a ground height every
    -- frame and cannot float) and one model, `marshall`, that fell back to the
    -- marker instead. So the marker's size matters for whatever the engine turns
    -- down and the prop's scale matters for the rest.
    ok(reg ~= nil and reg.fallbackMarker == 36
           and tonumber(reg.fallbackMarkerScale) == 0.375,
        'the fallback marker carries its own size, in metres, beside its id',
        reg and tostring(reg.fallbackMarkerScale) or 'unregistered')

    -- ═══ AND THE TWO STILL MOVE TOGETHER, FOR A BETTER REASON THAN BEFORE ═══
    --
    -- They used to be kept equal as a hedge: nobody knew which one drew the
    -- pickup, so his 75% went on both. Now that both paths are known to be live,
    -- equality is a REQUIREMENT rather than a hedge -- the marshall's token and
    -- the caracara2's are one thing to a player, and one of them being a
    -- different size from the other is a bug he would report as such.
    ok(BR.Config.Shop.tokenScale == BR.Config.Shop.tokenMarkerScale,
        'both knobs carry the same 75%, so the token a player picks up is the '
            .. 'same size whichever path drew it',
        ('prop %s, marker %s'):format(tostring(BR.Config.Shop.tokenScale),
                                      tostring(BR.Config.Shop.tokenMarkerScale)))

    -- THEY ARE NOT THE SAME NUMBER AND MUST NOT BE READ AS ONE. propScale is a
    -- multiple of the model's size; the marker scale is metres. This asserts
    -- they are separate FIELDS -- if a future edit collapsed them, raising one
    -- would silently move the other.
    --
    -- COUNTED, NOT MERELY FOUND. `fallbackMarkerScaleOf` appearing once is a
    -- function that is DEFINED AND NEVER CALLED -- which is exactly what
    -- reverting the draw site to a literal leaves behind, and a bare `find`
    -- passes it happily. Two occurrences is the definition plus the call.
    local loot = readFile(RES .. 'br_core/client/loot.lua')
    local uses = 0
    for _ in loot:gmatch('fallbackMarkerScaleOf') do uses = uses + 1 end
    ok(uses >= 2,
        'and client/loot.lua CALLS it rather than merely defining it', uses)
    ok(loot:find('%f[%w]0%.5, 0%.5, 0%.5') == nil,
        'so no literal marker size is left at the draw site')
end

-- ---------------------------------------------------------------------------
describe('which car a press resolves to, at his spacing')
-- ---------------------------------------------------------------------------
--
-- ═══ THIS IS THE BLOCK HIS COORDINATES MADE NECESSARY ═══
--
-- Twelve of his thirteen cars have a neighbour closer than the old 6.0m
-- `minSpacingM`, and the tightest pair -- `sanchez` and `outlaw` -- stand 3.25m
-- apart. There is no reach radius that puts one of those two in range without
-- the other: it would have to be under 1.63m, which is inside both cars. So
-- "the car in reach" is not a well-defined thing on this pad and never can be,
-- and the only correct answer is THE NEAREST ONE.
--
-- Every assertion below runs against the SHIPPED catalogue rather than a
-- fixture, because the property under test is a property of his geometry.
do
    local SROWS = BR.ShopSolve.catalogue(BR.Config.Shop,
                                         BR.Config.Shop.refusedReason)
    local reach = BR.Config.Shop.reachM
    local function row(id) return BR.ShopSolve.rowById(SROWS, id) end
    local function d(a, b) return BR.Dist(a.x, a.y, b.x, b.y) end

    -- ═══ THE TWO CLOSEST CARS HE SURVEYED ═══
    local A, B = row('sanchez'), row('outlaw')
    local sep = d(A, B)
    ok(sep > 3.2 and sep < 3.3,
        'his two closest cars are 3.25m apart -- the case the old code called '
            .. 'a coin flip', ('%.4f'):format(sep))

    -- Stand on the line between them, four tenths of the way across: 1.30m from
    -- the sanchez and 1.95m from the outlaw.
    local function between(p, q, t)
        return p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t
    end

    for _, c in ipairs({
        { t = 0.40, near = A, far = B, name = 'sanchez' },
        { t = 0.60, near = B, far = A, name = 'outlaw'  },
    }) do
        local px, py = between(A, B, c.t)
        local dn = BR.Dist(px, py, c.near.x, c.near.y)
        local df = BR.Dist(px, py, c.far.x,  c.far.y)

        -- THE AMBIGUITY HAS TO BE REAL FOR THE TEST TO MEAN ANYTHING. If the
        -- further car were out of reach the resolver would be picking between
        -- one candidate and none, and a broken resolver would pass.
        ok(dn <= reach and df <= reach and df > dn,
            ('standing here BOTH cars are in reach (%.2fm and %.2fm) -- the '
             .. 'ambiguity is real'):format(dn, df))

        local got = BR.ShopSolve.nearest(SROWS, px, py, reach)
        ok(got == c.near,
            'and the press resolves to the NEARER one, ' .. c.name ..
                ' -- never the further one',
            got and got.id or 'nil')
    end

    -- ═══ AND FROM EVERY CAR ON THE PAD, NOT JUST THAT PAIR ═══
    --
    -- Standing on a car's own coordinates must resolve to that car. Thirteen
    -- assertions; an ordering or tie-break slip anywhere in the sweep shows up
    -- as the wrong id here.
    local overlapping = 0
    for _, r in ipairs(SROWS) do
        local got = BR.ShopSolve.nearest(SROWS, r.x, r.y, reach)
        ok(got == r, 'standing at ' .. r.id .. ' resolves to ' .. r.id,
            got and got.id or 'nil')

        for _, other in ipairs(SROWS) do
            if other ~= r and d(r, other) <= reach then
                overlapping = overlapping + 1
                break
            end
        end
    end
    ok(overlapping >= 12,
        'and twelve of the thirteen have a neighbour inside the reach radius '
            .. '-- two cars in range is the NORMAL case here, not the edge one',
        overlapping)

    -- ═══ THE CATALOGUE IS NOT ONE CLUSTER, AND NOTHING MAY ASSUME IT IS ═══
    --
    -- `veto` stands 154m from the other twelve, where he put it. A resolver
    -- that walked outwards from the last answer, or stopped at the first row in
    -- range, would work perfectly on the line and fail on the outlier.
    local V = row('veto')
    ok(d(V, row('marshall')) > 150.0,
        'veto stands 154m from its nearest neighbour -- deliberately',
        ('%.1f'):format(d(V, row('marshall'))))
    ok(BR.ShopSolve.nearest(SROWS, V.x, V.y, reach) == V,
        'and standing at it resolves to it, from the far side of the survey')
    ok(BR.ShopSolve.nearest(SROWS, A.x, A.y, reach) ~= V,
        'while standing in the line never reaches it')

    -- ═══ REACH IS A GATE, NOT A CHOOSER ═══
    ok(BR.ShopSolve.nearest(SROWS, V.x + reach + 1.0, V.y, reach) == nil,
        'past the reach radius there is no car and no plate')
    ok(BR.ShopSolve.nearest(SROWS, V.x, V.y, 0.0) == nil
           and BR.ShopSolve.nearest(SROWS, V.x, V.y, nil) == nil,
        'and a reach of zero or none offers nothing rather than everything')

    -- A ROW WHOSE CAR NEVER STREAMED IS NOT FOR SALE. The client passes its
    -- DoesEntityExist check in here; skipping it after the fact would offer
    -- nothing while a good car stood two metres further on.
    local px, py = between(A, B, 0.40)
    local got = BR.ShopSolve.nearest(SROWS, px, py, reach,
                                     function(r) return r.id ~= 'sanchez' end)
    ok(got == B,
        'a car that is not standing is skipped, and the next nearest is '
            .. 'offered instead of nothing', got and got.id or 'nil')

    -- TIES GO TO THE EARLIER ROW, so a player standing exactly between two cars
    -- gets a stable answer rather than a plate that flickers.
    local T = {
        { id = 'first',  model = 'blista', price = 1, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'second', model = 'blista', price = 1, x = 4.0, y = 0.0, z = 0.0 },
    }
    ok(BR.ShopSolve.nearest(T, 2.0, 0.0, 5.0) == T[1],
        'and an exact tie resolves to the earlier row, every time')

    -- ═══ THE TUNING ═══
    --
    -- `minSpacingM` warns about cars standing inside one another. Against his
    -- pad it must fire on NOTHING -- it used to print ten lines at every boot,
    -- which is a warning nobody reads.
    local tight, closest = 0, math.huge
    for i = 1, #SROWS do
        for j = i + 1, #SROWS do
            local dd = d(SROWS[i], SROWS[j])
            closest = math.min(closest, dd)
            if dd < BR.Config.Shop.minSpacingM then tight = tight + 1 end
        end
    end
    ok(tight == 0,
        'minSpacingM is quiet on his thirteen rows -- the console warning is a '
            .. 'signal again rather than ten lines of noise', tight)
    ok(BR.Config.Shop.minSpacingM < closest,
        'because it sits below his tightest pair rather than above it',
        ('%.2f < %.2f'):format(BR.Config.Shop.minSpacingM, closest))

    -- ...and `reachM` must clear HALF the tightest gap, or there is a dead spot
    -- between two cars where a player is at neither of them.
    ok(reach > closest / 2.0,
        'and reachM covers the midpoint of the tightest pair, so walking the '
            .. 'line never drops the plate into a gap',
        ('%.2f > %.2f'):format(reach, closest / 2.0))
end

-- ---------------------------------------------------------------------------
-- THE FIXTURE. Three sellable cars and one that must be thrown out.
-- ---------------------------------------------------------------------------

local FIXTURE = {
    enabled = true,
    limit   = 1,
    reachM  = 4.0,
    minSpacingM = 6.0,
    useMs   = 3000,
    tokenScale  = 0.1,
    tokenMarker = 34,
    spawnAheadM = 5.0,
    signLabel   = BR.Config.Shop.signLabel,
    -- THE SHIPPED STRINGS, BY REFERENCE. Both halves of the purchase toast are
    -- the owner's wording, so what the handler is exercised against below is
    -- what a player actually reads -- not a copy of it that could be edited to
    -- agree with a broken join.
    boughtToast  = BR.Config.Shop.boughtToast,
    balanceToast = BR.Config.Shop.balanceToast,
    cue         = BR.Config.Shop.cue,
    lockedState = 2,
    items = {
        {
            id = 'runner', model = 'sultan', label = 'Sultan',
            price = 750, vtype = 'automobile',
            x = 100.0, y = 200.0, z = 30.0, heading = 90.0,
            appearance = {
                primary = 27, secondary = 12, pearl = 3, wheelColour = 0,
                windowTint = 1, wheelType = 0, dirt = 0.0,
                plate = 'BR SHOP', plateIndex = 0,
                mods = { [11] = 2, [23] = 4, [12] = 1 },
                toggles = { [18] = true },
                extras = { [1] = true, [2] = false },
            },
        },
        {
            -- A SECOND PRICE, because answer 2 is "per-model price, in config".
            id = 'hauler', model = 'bison', price = 400,
            x = 140.0, y = 200.0, z = 30.0, heading = 90.0,
        },
        {
            -- NO APPEARANCE BLOCK AT ALL. A half-filled row has to be safe.
            id = 'plain', model = 'blista', price = 100,
            x = 180.0, y = 200.0, z = 30.0, heading = 0.0,
        },
        {
            -- BANNED. `lazer` is in BR.Config.RefusedVehicles because it flies.
            id = 'cheat', model = 'lazer', price = 10,
            x = 220.0, y = 200.0, z = 30.0, heading = 0.0,
        },
    },
}

local FROWS, FREJECTS = BR.ShopSolve.catalogue(FIXTURE,
                                               BR.Config.Shop.refusedReason)
local function frow(id) return BR.ShopSolve.rowById(FROWS, id) end

-- ---------------------------------------------------------------------------
describe('the catalogue is the safety mechanism')
-- ---------------------------------------------------------------------------
do
    ok(#FROWS == 3, 'three of the four fixture rows are sellable', #FROWS)

    ok(frow('cheat') == nil,
        'and a BANNED model is not one of them -- an aircraft cannot be sold')

    local found = nil
    for _, r in ipairs(FREJECTS) do if r.id == 'cheat' then found = r end end
    ok(found ~= nil and found.why:find('refused', 1, true) ~= nil,
        'the refusal is REPORTED rather than silent, and it says why',
        found and found.why)

    -- ═══ THE REFUSAL IS THE SHIPPED TABLE'S, NOT THIS FILE'S ═══
    --
    -- The point of hashing `lazer` to its real 0xB39B0AE6 is that this asserts
    -- config/vehicles.lua actually refusing a model it actually lists. A stub
    -- that answered "banned" would pass this test with the whole ban list
    -- deleted.
    local allowed = BR.Config.IsAllowedVehicle(GetHashKey('lazer'))
    ok(allowed == false,
        'because BR.Config.IsAllowedVehicle refuses it -- the same one function '
            .. 'BR.Vehicles.spawnOwned asks')

    -- A row for a car that IS allowed must survive, or the check is just a
    -- switch that turns the shop off.
    ok(BR.Config.IsAllowedVehicle(GetHashKey('sultan')) == true
           and frow('runner') ~= nil,
        'and an ordinary car is not caught by it')

    -- DUPLICATES, which would otherwise produce two rows selling one item id
    -- and a delivery that could come from either.
    local dup = { enabled = true, items = {
        { id = 'a', model = 'sultan', price = 1, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'a', model = 'blista', price = 2, x = 0.0, y = 0.0, z = 0.0 },
    } }
    local drows, drej = BR.ShopSolve.catalogue(dup, BR.Config.Shop.refusedReason)
    ok(#drows == 1 and #drej == 1 and drej[1].why == 'duplicate id',
        'two rows with one id: the second is thrown out and named')

    -- MALFORMED ROWS. Each of these would otherwise reach the world as a car
    -- with no price, no position, or a price nobody could pay.
    local bad = { enabled = true, items = {
        { model = 'sultan', price = 1, x = 0.0, y = 0.0, z = 0.0 },          -- no id
        { id = 'b', price = 1, x = 0.0, y = 0.0, z = 0.0 },                  -- no model
        { id = 'c', model = 'sultan', x = 0.0, y = 0.0, z = 0.0 },           -- no price
        { id = 'd', model = 'sultan', price = 0, x = 0.0, y = 0.0, z = 0.0 },-- free
        { id = 'e', model = 'sultan', price = -5, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'f', model = 'sultan', price = 7.5, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'g', model = 'sultan', price = 1 },                           -- nowhere
    } }
    local brows = BR.ShopSolve.catalogue(bad, BR.Config.Shop.refusedReason)
    ok(#brows == 0, 'and seven differently-broken rows all fail to reach the pad',
        #brows)
end

-- ---------------------------------------------------------------------------
describe('exactly as shown')
-- ---------------------------------------------------------------------------
do
    local row = frow('runner')

    -- ═══ THE APPEARANCE IS TOTAL ═══
    --
    -- Every field is present in the answer even when the row omits it, because
    -- a dresser that skips absent fields leaves a freshly created vehicle
    -- wearing the RANDOM COLOUR the engine gives it -- and a random colour is
    -- different on the showroom car and on the bought car by definition.
    local plain = BR.ShopSolve.appearance(frow('plain'))
    for _, k in ipairs({ 'primary', 'secondary', 'pearl', 'wheelColour',
                         'interior', 'dashboard', 'livery', 'roofLivery',
                         'windowTint', 'wheelType', 'plateIndex',
                         'xenonColour' }) do
        ok(plain[k] == -1,
            ('a row with no appearance block still answers %s, as an explicit '
             .. '"the model\'s own default"'):format(k), plain[k])
    end
    ok(type(plain.mods) == 'table' and next(plain.mods) == nil
           and type(plain.toggles) == 'table' and type(plain.extras) == 'table',
        'and the three collections are empty tables rather than nil')

    -- ═══ TWO CALLS AGREE, WHICH IS THE WHOLE PROMISE ═══
    --
    -- The showroom car is dressed at warmup and the bought car forty minutes
    -- later, both from this function over this row. If two calls could differ,
    -- nothing else in the feature could save it.
    local a1 = BR.ShopSolve.appearance(row)
    local a2 = BR.ShopSolve.appearance(row)
    local same = true
    for k, v in pairs(a1) do
        if type(v) ~= 'table' and a2[k] ~= v then same = false end
    end
    for slot, idx in pairs(a1.mods) do
        if a2.mods[slot] ~= idx then same = false end
    end
    ok(same, 'the same row dressed twice is the same car, field for field')

    ok(a1.primary == 27 and a1.secondary == 12 and a1.plate == 'BR SHOP'
           and a1.mods[11] == 2 and a1.mods[23] == 4
           and a1.toggles[18] == true,
        'and it is the AUTHORED car rather than a defaulted one')

    -- ═══ EXTRAS READ THE WAY A PERSON WOULD EXPECT ═══
    --
    -- SET_VEHICLE_EXTRA takes `true` to mean DISABLED. The inversion happens in
    -- exactly one place (BR.Shop.dress) and the config is written the human way,
    -- so this asserts the config's polarity survives normalisation.
    ok(a1.extras[1] == true and a1.extras[2] == false,
        'an extra the owner turned ON arrives here as true')

    -- ═══ THE CALLER CANNOT WRITE BACK INTO THE CONFIG ═══
    --
    -- A defaulted field written back into the shared row would be a second
    -- representation of the appearance arriving by the back door -- one client
    -- would have persisted its own defaults into the table every other reader
    -- uses.
    a1.mods[99] = 7
    a1.primary = 0
    local a3 = BR.ShopSolve.appearance(row)
    ok(a3.mods[99] == nil and a3.primary == 27,
        'and mutating the answer cannot reach the authored row')

    -- ═══ STRUCTURE: ONE DRESSER, TWO CALLERS ═══
    --
    -- The behavioural half above proves the FUNCTION is deterministic. This
    -- half proves that both cars actually go through it -- which is the claim a
    -- refactor could quietly break while every test above kept passing.
    local cli = readFile(RES .. 'br_core/client/shop.lua')
    local calls = 0
    for _ in cli:gmatch('BR%.Shop%.dress%(') do calls = calls + 1 end
    ok(calls == 3,
        'client/shop.lua declares BR.Shop.dress once and calls it exactly '
            .. 'twice -- the showroom car and the bought car', calls)

    -- ═══ AND NOTHING ABOUT AN APPEARANCE IS ON THE WIRE ═══
    --
    -- The delivery message carries a net id and a catalogue id. If it ever
    -- carried a colour, a mod list or a plate, there would be a second
    -- description of the car in flight -- which is the drift this whole design
    -- exists to make impossible.
    local srv = readFile(RES .. 'br_core/server/shop.lua')
    for _, forbidden in ipairs({ 'primary', 'secondary', 'livery', 'mods',
                                 'plate', 'appearance', 'windowTint' }) do
        ok(srv:find("TriggerClientEvent%('br:shop:dress'[^\n]*" .. forbidden) == nil,
            ('the delivery message does not carry "%s"'):format(forbidden))
    end
    ok(srv:find('BR.ShopSolve.appearance', 1, true) == nil
           and srv:find('SetVehicleMod', 1, true) == nil
           and srv:find('SetVehicleColours', 1, true) == nil,
        'and the server never touches an appearance at all')
end

-- ---------------------------------------------------------------------------
describe('the item')
-- ---------------------------------------------------------------------------
do
    -- Registration is what turns a catalogue row into something the inventory,
    -- the ground, the label and the drop all already know how to handle.
    local before = {}
    for id in pairs(BR.Config.ConsumableById) do before[id] = true end

    local saved = BR.Config.Shop
    BR.Config.Shop = FIXTURE
    FIXTURE.register = saved.register
    FIXTURE.refusedReason = saved.refusedReason
    local rrows = FIXTURE.register(saved.refusedReason)
    BR.Config.Shop = saved

    ok(#rrows == 3, 'registering the fixture registers its three sellable rows')

    local item = BR.Config.ConsumableById['car_runner']
    ok(item ~= nil, 'the Sultan is an ordinary consumable, by item id')
    ok(BR.ShopSolve.itemIdFor(frow('runner')) == 'car_runner',
        'and its item id is derived from the row rather than authored twice')
    ok(('car_runner'):find(':', 1, true) == nil,
        'with no colon in it -- item ids become artwork filenames')

    ok(item.maxStack == 1 and item.carryMax == 1,
        'CARRY ONE, STACK ONE: one purchase is one car')
    ok(type(item.useMs) == 'number' and item.useMs > 0,
        'it declares useMs, which is what makes a consumable usable by hand at '
            .. 'all (server/inventory.lua refuses one that does not)')
    ok(item.shopCar == 'runner',
        'and it names the row that built it, which is how the delivered car is '
            .. 'dressed from the same table the showroom car was')
    ok(item.label == 'Sultan',
        'the label is the owner\'s, not the model string, when he wrote one')

    ok(item.health == nil and item.armour == nil,
        'it heals nothing -- a car is not a potion')

    -- ═══ IN NO RARITY BUCKET, WHICH IS THE CPR KIT'S PATTERN ═══
    --
    -- BR.Config.ConsumablesByRarity is what BR.RollLootStack rolls against.
    -- A car in it would be a car in every crate on the map that rolls its tier.
    local rollable = false
    for _, bucket in pairs(BR.Config.ConsumablesByRarity or {}) do
        for _, c in ipairs(bucket) do
            if c.id == 'car_runner' then rollable = true end
        end
    end
    ok(rollable == false,
        'and it is in NO rarity bucket, so no crate on the map can ever roll a '
            .. 'car')

    -- THE GROUND TOKEN.
    ok(item.prop == 'sultan',
        'dropped, its prop is the CAR -- the owner asked for the vehicle itself')
    ok(item.propScale == 0.1,
        'at a tenth of its authored size, which is what makes it pickup-sized',
        item.propScale)
    ok(item.fallbackMarker == 34,
        'and it carries the owner\'s stated fallback for the case where the '
            .. 'engine will not build a vehicle as an object')

    -- PER-ROW OVERRIDE, because a Sanchez and a Bison are not the same size to
    -- begin with and the scale is a multiple rather than a measurement.
    ok(BR.ShopSolve.tokenScale({ tokenScale = 0.25 }, FIXTURE) == 0.25,
        'a row may override the token scale')
    ok(BR.ShopSolve.tokenScale({}, { tokenScale = 0.2 }) == 0.2,
        'and the catalogue default applies when it does not')

    -- The registration must not have disturbed anything already there.
    ok(BR.Config.ConsumableById['cprkit'] ~= nil
           and BR.Config.ConsumableById['medkit'] ~= nil,
        'registering cars leaves the existing consumables alone')
    ok(before['car_runner'] == nil,
        'and nothing named a car before the fixture was registered')
end

-- ---------------------------------------------------------------------------
describe('the purchase condition')
-- ---------------------------------------------------------------------------
do
    local row = frow('runner')
    local function st(over)
        local s = {
            on = true,
            matchState = BR.MatchState.WARMUP,
            playerState = BR.PlayerState.WARMUP,
            row = row, bought = 0, limit = 1,
            balance = 1000, price = row.price,
        }
        for k, v in pairs(over or {}) do s[k] = v end
        return s
    end

    ok(select(1, BR.ShopSolve.canBuy(st())) == true,
        'a warmup player with the money buys the car')

    -- ═══ WARMUP ON BOTH CLOCKS ═══
    for _, s in ipairs({ BR.MatchState.PLAYING, BR.MatchState.BUS,
                         BR.MatchState.ENDED, BR.MatchState.WAITING }) do
        local can, why = BR.ShopSolve.canBuy(st({ matchState = s }))
        ok(can == false and why == BR.ShopSolve.Refusal.STATE,
            ('the shop is shut once the match is %s'):format(s))
    end
    -- ═══ COUNTED, BECAUSE A SHORT ipairs IS A SILENT ONE ═══
    --
    -- This list used to name four states, two of which were SPECTATING and
    -- DEAD. #233 deleted the first and renamed the second, and a table
    -- constructor holding a nil is where that gets dangerous: `ipairs` STOPS
    -- at the first nil rather than skipping it, so a stale name here would
    -- have quietly cut this loop from four iterations to two AND STILL PASSED.
    -- Measured, not reasoned about -- that is exactly what it did.
    --
    -- So the count is asserted. Any future rename that leaves a name behind
    -- goes red here instead of silently testing less than it claims to.
    local shutStates = { BR.PlayerState.ALIVE, BR.PlayerState.LOBBY,
                         BR.PlayerState.OUT }
    local shutSeen = 0
    for _, s in ipairs(shutStates) do
        shutSeen = shutSeen + 1
        local can, why = BR.ShopSolve.canBuy(st({ playerState = s }))
        ok(can == false and why == BR.ShopSolve.Refusal.STATE,
            ('and shut to a player who is %s during one'):format(s))
    end
    ok(shutSeen == 3,
        'and all three of those states were actually reached -- a nil from a '
            .. 'stale PlayerState name would truncate this loop, not skip it',
        shutSeen)

    -- ═══ ONE VEHICLE PER PLAYER PER MATCH ═══
    local can, why = BR.ShopSolve.canBuy(st({ bought = 1 }))
    ok(can == false and why == BR.ShopSolve.Refusal.BOUGHT,
        'a second car is refused -- "no more than 1 vehicle during warmup"')
    ok(select(1, BR.ShopSolve.canBuy(st({ bought = 1, limit = 2 }))) == true,
        'and the limit is a NUMBER in config, so two is one edit away')

    -- ═══ THE PRICE ═══
    can, why = BR.ShopSolve.canBuy(st({ balance = 749 }))
    ok(can == false and why == BR.ShopSolve.Refusal.AFFORD,
        'one Volt short is a refusal')
    ok(select(1, BR.ShopSolve.canBuy(st({ balance = 750 }))) == true,
        'and spending your last Volt is a purchase, not an overdraft')
    ok(BR.ShopSolve.shortfall(749, 750) == 1,
        'the shortfall is what the market\'s existing sentence needs')

    -- PER-MODEL PRICING (answer 2). The Bison is cheaper and it is the ROW that
    -- says so.
    ok(frow('hauler').price == 400 and frow('runner').price == 750,
        'two cars, two prices, both authored')
    ok(select(1, BR.ShopSolve.canBuy(st({ row = frow('hauler'),
                                          price = frow('hauler').price,
                                          balance = 400 }))) == true,
        'and 400 Volts buys the 400-Volt car')
    can, why = BR.ShopSolve.canBuy(st({ row = frow('hauler'),
                                        price = frow('hauler').price,
                                        balance = 399 }))
    ok(can == false and why == BR.ShopSolve.Refusal.AFFORD,
        'but not the 750 one')

    -- A CAR THAT IS NOT FOR SALE.
    --
    -- Built by hand rather than through `st`, because `{ row = nil }` is an
    -- EMPTY TABLE in Lua and the override loop would never see the key -- which
    -- is a test that passes by not testing anything.
    local absent = st()
    absent.row = nil
    can, why = BR.ShopSolve.canBuy(absent)
    ok(can == false and why == BR.ShopSolve.Refusal.NOROW,
        'and naming a car that is not in the catalogue buys nothing')
end

-- ---------------------------------------------------------------------------
-- The server half, driven for real.
-- ---------------------------------------------------------------------------

local roster = {}
local matches = {}
local inv = {}
local dropped = {}
local notices = {}
local charged = {}
local spawned = {}
local spawnFails = false

BR.Server = {
    matchOf = function(src) return roster[src] and matches[roster[src].matchId] end,
    notify = function(src, text, tone)
        notices[#notices + 1] = { src = src, text = text, tone = tone }
    end,
}
BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        local ids = {}
        for src in pairs(roster) do ids[#ids + 1] = src end
        table.sort(ids)
        for _, src in ipairs(ids) do
            if pred(roster[src]) then fn(src, roster[src]) end
        end
    end,
}
BR.Market = {
    balances = {},
    balanceOf = function(src) return BR.Market.balances[src] or 0 end,
    tellShortfall = function(src, price)
        notices[#notices + 1] = { src = src, text = 'shortfall', tone = 'warn' }
    end,
    -- ═══ THE CHARGE IS A DYNAMODB ROUND TRIP AND THE STUB CAN HOLD IT OPEN ═══
    --
    -- `BR.Market.charge` answers through a CALLBACK now, because the debit is a
    -- conditional write against the real row rather than a number moving in this
    -- process. Everything the purchase does -- the record, the toast, the cue --
    -- happens inside that callback, so a stub that answered by RETURNING would
    -- test a shape the server no longer has.
    --
    -- `hold` DEFERS THE ANSWER instead of refusing it, which is the only way to
    -- stand a second keypress inside the round trip. Without it the in-flight
    -- refusal below cannot be reached at all, and "two presses buy two cars" is
    -- exactly the bug an async charge introduces if nothing guards it.
    hold = false,
    held = {},
    -- ═══ THE ROW SAYING NO WHILE THE CACHE SAID YES ═══
    --
    -- The one case the cache cannot produce on its own, and the reason the
    -- authority moved to DynamoDB: a report award, a console grant or a second
    -- server can move the row between the read on connect and the press. Set
    -- this and the charge is refused with the money apparently there.
    refuseNext = false,
    charge = function(src, amount, reason, done)
        done = done or function() end
        local function settle()
            if BR.Market.refuseNext then
                BR.Market.refuseNext = false
                done(false, 'not enough currency')
                return
            end
            if (BR.Market.balances[src] or 0) < amount then
                BR.Market.tellShortfall(src, amount)
                done(false, 'poor')
                return
            end
            BR.Market.balances[src] = BR.Market.balances[src] - amount
            charged[#charged + 1] = { src = src, amount = amount, reason = reason }
            -- ═══ THE THIRD ARGUMENT IS THE BALANCE AFTER THE DEBIT (#239) ═══
            --
            -- The real BR.Market.charge takes it from `br:ddb:spend`'s
            -- UPDATED_NEW answer -- the row's own figure -- and hands it to the
            -- caller so nothing has to re-derive it. Handed back here for the
            -- same reason the `quiet` option is recorded: a stub that swallowed
            -- it would let the toast go back to arithmetic on a cache with
            -- every assertion in this file still green.
            done(true, nil, BR.Market.balances[src])
        end
        if BR.Market.hold then
            BR.Market.held[#BR.Market.held + 1] = settle
        else
            settle()
        end
    end,
}

--- Let every held charge answer, oldest first.
local function settleCharges()
    local due = BR.Market.held
    BR.Market.held = {}
    for _, fn in ipairs(due) do fn() end
end
BR.Vehicles = {
    spawnOwned = function(model, vtype, x, y, z, heading, forSrc)
        if spawnFails then return nil, nil, 'the engine refused it (handle 0)' end
        spawned[#spawned + 1] = {
            model = model, vtype = vtype, x = x, y = y, z = z,
            heading = heading, forSrc = forSrc,
        }
        return 500 + #spawned, 9000 + #spawned, nil
    end,
}
--- WHAT THE LAST give WAS ASKED FOR, options included.
---
--- The third argument is the whole of the owner's pickup-sound fix, so the stub
--- has to record it. A stub that swallowed it would let the delivery go back to
--- being noisy with every test in this file still green.
local lastGive = nil
BR.Inv = {
    give = function(src, stack, opts)
        lastGive = { src = src, stack = stack, opts = opts }
        inv[src] = inv[src] or {}
        if #inv[src] >= 5 then return false, nil, 'carrymax' end
        inv[src][#inv[src] + 1] = stack
        return true, nil, nil
    end,
}
BR.Loot = {
    dropForPlayer = function(src, stack)
        dropped[#dropped + 1] = { src = src, stack = stack }
    end,
}

-- THE FIXTURE IS INSTALLED AS THE CONFIG BEFORE server/shop.lua RESOLVES IT.
-- Everything below therefore exercises the real handler against three cars that
-- exist rather than against a shipped table that is empty on purpose.
local shipped = BR.Config.Shop
FIXTURE.register       = shipped.register
FIXTURE.refusedReason  = shipped.refusedReason
BR.Config.Shop = FIXTURE

loadCore('br_core/server/shop.lua')
handlers['onResourceStart']('br_core')

local function reset()
    sent, notices, charged, spawned, dropped = {}, {}, {}, {}, {}
    inv, roster, matches, peds = {}, {}, {}, {}
    BR.Market.balances = {}
    BR.Market.hold, BR.Market.held = false, {}
    BR.Market.refuseNext = false
    spawnFails = false
end

--- The purchases a player is currently carrying, in order.
local function buysOf(src)
    return (roster[src] and roster[src].shopBuys) or {}
end

local function player(src, opts)
    opts = opts or {}
    matches[1] = matches[1] or { id = 1, state = BR.MatchState.WARMUP }
    roster[src] = {
        matchId = 1,
        state = opts.state or BR.PlayerState.WARMUP,
        pos = { x = 0.0, y = 0.0, z = 30.0 },
    }
    peds[src] = { ped = 900 + src, x = 0.0, y = 0.0, z = 30.0, heading = 0.0 }
    BR.Market.balances[src] = opts.balance or 1000
end

local function buy(src, id)
    _G.source = src
    handlers['br:shop:buy']({ id = id })
end

-- ---------------------------------------------------------------------------
describe('buying, for real')
-- ---------------------------------------------------------------------------
do
    reset()
    player(10)
    buy(10, 'runner')

    ok(#charged == 1 and charged[1].amount == 750,
        'the purchase charges the price off the ROW, not off anything the '
            .. 'client sent', charged[1] and charged[1].amount)
    ok(#buysOf(10) == 1 and buysOf(10)[1].row == 'runner'
           and buysOf(10)[1].paid == 750,
        'and the purchase is recorded against the player, with what it cost -- '
            .. 'which is what the forfeit line quotes back')

    -- ═══ THE OWNER'S TWO SENTENCES, VERBATIM, IN ONE TOAST ═══
    --
    -- #239: "'Thank you for your purchase.' toast should also include a note
    -- about their new balance, stated as 'Your new balance is: [X] Volts.'"
    --
    -- THE FIGURE IS THE ONE THE CHARGE LEFT BEHIND, not the price subtracted
    -- from anything here: the player started on 1000 and the runner costs 750,
    -- so 250 is what the row holds and 250 is what the toast must say.
    ok(#notices == 1 and notices[1].text ==
        'Thanks for your purchase. It will be available in your inventory '
        .. 'once the match starts. Your new balance is: 250 Volts.',
        'the toast is the owner\'s wording, exactly, both sentences of it',
        notices[1] and notices[1].text)
    ok(#notices == 1,
        'and it is ONE toast rather than two -- a second notification would '
            .. 'stack on the first and push it off the top', #notices)

    ok(#sent == 1 and sent[1].name == 'br:shop:bought',
        'and the client is told, so it can play the existing pickup cue')

    -- A SECOND CAR IS REFUSED AND COSTS NOTHING.
    buy(10, 'hauler')
    ok(#charged == 1, 'a second purchase charges nothing at all', #charged)
    ok(#buysOf(10) == 1 and buysOf(10)[1].row == 'runner',
        'and does not overwrite the first')

    -- A CLIENT NAMING A CAR THAT IS NOT FOR SALE.
    reset()
    player(11)
    buy(11, 'cheat')          -- the banned row
    ok(#charged == 0 and #buysOf(11) == 0,
        'the banned model cannot be bought even by naming it directly')
    buy(11, 'nonesuch')
    ok(#charged == 0, 'nor can a car that was never in the catalogue')

    -- MONEY.
    reset()
    player(12, { balance = 749 })
    buy(12, 'runner')
    ok(#charged == 0 and #buysOf(12) == 0,
        'a player one Volt short buys nothing')
    ok(#notices == 1 and notices[1].text == 'shortfall',
        'and is told in the market\'s own words rather than in invented ones')

    -- STATE.
    reset()
    player(13)
    matches[1].state = BR.MatchState.PLAYING
    buy(13, 'runner')
    ok(#charged == 0, 'and the shop is shut once the bus has gone')
end

-- ---------------------------------------------------------------------------
describe('the debit is DynamoDB\'s answer, not this process\'s')
-- ---------------------------------------------------------------------------
do
    -- ═══ NOTHING EXISTS UNTIL THE WRITE LANDS ═══
    --
    -- The debit used to be a number moving in memory, settled into the match's
    -- payout at the end. It is a conditional write now (`br:ddb:spend`), so
    -- there is a window between the press and the answer -- and everything the
    -- purchase produces has to be on the far side of it. A record, a toast or a
    -- cue emitted early is a car that briefly existed and then did not.
    reset()
    player(30)
    BR.Market.hold = true
    buy(30, 'runner')

    ok(#buysOf(30) == 0, 'a charge in flight has bought nothing yet')
    ok(#notices == 0 and #sent == 0,
        'and has promised the player nothing yet either')

    -- ═══ AND A SECOND PRESS INSIDE THAT WINDOW BUYS NOTHING ═══
    --
    -- The refusal that an async charge makes possible and that nothing else
    -- catches: both presses see zero purchases recorded, because the first has
    -- not finished. It is `alreadyone` rather than `afford`.
    buy(30, 'hauler')
    settleCharges()
    ok(#charged == 1 and charged[1].amount == 750,
        'two presses inside one round trip are charged once', #charged)
    ok(#buysOf(30) == 1 and buysOf(30)[1].row == 'runner',
        'and produce one car, the one that was pressed first')
    ok(#notices == 1, 'and one toast', #notices)

    -- ...AND THE WINDOW CLOSES. The guard must not outlive the answer.
    reset()
    player(31)
    BR.Market.hold = true
    buy(31, 'runner')
    settleCharges()
    ok(#buysOf(31) == 1, 'the first purchase lands once the write answers')
    buy(31, 'hauler')
    ok(#charged == 1,
        'and the ceiling -- not a stuck in-flight flag -- is what refuses the '
            .. 'next one', #charged)

    -- ═══ A REFUSED WRITE LEAVES NOTHING BEHIND ═══
    --
    -- ROW-SIDE, NOT CACHE-SIDE, AND THAT IS THE WHOLE POINT OF THE TEST. A
    -- player who obviously cannot afford the car is turned away by
    -- BR.ShopSolve.canBuy before any charge is attempted, so that case never
    -- reaches the callback. This one has the money as far as this process knows
    -- and is refused by DynamoDB anyway -- which is the case the old design
    -- could not even represent, and the only one that exercises what the
    -- callback does with a "no".
    reset()
    player(32, { balance = 5000 })
    BR.Market.refuseNext = true
    buy(32, 'runner')
    ok(#buysOf(32) == 0, 'a refused charge records no purchase', #buysOf(32))
    ok(#sent == 0 and #notices == 0,
        'and neither promises the player a car nor plays them a cue',
        ('%d events, %d toasts'):format(#sent, #notices))

    buy(32, 'runner')
    ok(#buysOf(32) == 1,
        'and does not consume the allowance -- the same player can try again',
        #buysOf(32))

    -- ═══ AND THE MATCH-END SETTLE IS GONE, WHICH IS THE OTHER HALF ═══
    --
    -- The debit used to ride br_core's session ledger and be folded into
    -- `deltas.balance` at match end. Now that the row is debited at the
    -- purchase, subtracting it again at match end would charge for the car
    -- TWICE -- and the two halves live in different resources, so nothing but
    -- this pins them together.
    --
    -- `takeSpent` WAS DELETED RATHER THAN LEFT RETURNING ZERO. A function that
    -- exists and answers 0 is one somebody re-wires.
    --
    -- COMMENTS STRIPPED FIRST. Both files explain at length what the settle
    -- USED to do and name the function while doing it; prose about a deleted
    -- call is exactly what these files should contain, and matching it would
    -- make this assertion a ban on explaining the change.
    local function code(s) return (s:gsub('%-%-[^\n]*', '')) end
    local mkt = code(readFile(RES .. 'br_core/server/market.lua'))
    local prs = code(readFile(RES .. 'br_stats/server/persist.lua'))
    ok(mkt:find("ask%('br:ddb:spend'") ~= nil,
        'BR.Market.charge writes the debit through br_ddb\'s spend verb')

    -- ═══ ...AND HANDS THE ROW'S OWN FIGURE BACK, WHICH IS #239's HALF OF IT
    --     ═══
    --
    -- The toast has to state the new balance, and the only number worth stating
    -- is the one DynamoDB holds after the write -- `br:ddb:spend` answers with
    -- ReturnValues UPDATED_NEW for exactly that reason. A caller subtracting the
    -- price from a cached balance would disagree with the row the moment another
    -- writer moved it, which is the staleness the debit was moved into DynamoDB
    -- to end.
    --
    -- ASSERTED ON THE SOURCE, because nothing in this tree loads server/market.lua
    -- for real -- this file stubs BR.Market wholesale so the shop handler can be
    -- driven, and a stub cannot prove what the real charge hands back. That is a
    -- real limit and this is the assertion that fits inside it: the success path
    -- passes a third argument, it is the same `spendable` figure BR.Market.push
    -- has just sent the Store screen, and the two-argument success -- which is
    -- what shipped before and what a revert would restore -- is gone.
    ok(mkt:find('local left = BR%.Market%.spendable%(entry%)') ~= nil,
        'and reads what is left ONCE, through the same spendable() the Store '
            .. 'screen is pushed')
    ok(mkt:find('done%(true, nil, left%)') ~= nil,
        'and hands it to the caller rather than making the caller re-derive it')
    ok(mkt:find('done%(true, nil%)') == nil,
        'and there is no two-argument success left to revert to -- a toast '
            .. 'quoting a balance nobody handed it would read "0 Volts"')
    ok(mkt:find('takeSpent') == nil,
        'and the session ledger\'s hand-off no longer exists')
    ok(prs:find('takeSpent') == nil,
        'so br_stats cannot settle a purchase that DynamoDB already took')
end

-- ---------------------------------------------------------------------------
describe('one car at wheels-up, ever')
-- ---------------------------------------------------------------------------
do
    -- ═══ THE OWNER'S BUG, 2026-08-30, AND IT IS THE PREVIOUS FIX'S OWN BUG ═══
    --
    -- "Confirmed the vehicle is dropped when leaving the WARMUP, nice. But now
    -- when I bought one the next round, and landed after the bus, I have BOTH
    -- vehicles in my inventory -- the one from the previous warmup and this
    -- warmup." His console: `shop: 1 received "car_caracara2"` and
    -- `shop: 1 received "car_marshall"` at one wheels-up.
    --
    -- THE ROUND BEFORE, the complaint was the opposite: "I bought a thing, left
    -- the match with it (and still in warmup), then joined a new match and
    -- couldn't buy anything else". The diagnosis then was right -- readying up
    -- while a warmup of your mode is still open re-enters the SAME instance
    -- with the SAME id (BR.Lobby.ready -> BR.Party.lateJoin), so a purchase he
    -- had walked away from was still binding him -- and the REMEDY was wrong.
    -- It made leaving a fresh allowance, which is how two paid-for cars came to
    -- exist at once.
    --
    -- ═══ AND THEN HE OVERRULED THE FIX, THE SAME DAY ═══
    --
    -- "#238 if you buy a car, then leave the match, you forfeit your purchase.
    -- It should not be persistent or carry over to another round ever."
    --
    -- The first remedy made leaving a fresh allowance (two cars). The second
    -- declined the second sale and kept the first owed (one car, nothing lost).
    -- He wants the third: leaving DESTROYS the purchase. He is content for the
    -- car to be lost and does not want purchases surviving a round under any
    -- circumstances, which settles the refund question in the same breath --
    -- forfeit, not refund, so no Volts come back.
    reset()
    -- Enough for both cars, so a refusal below can only be the CEILING and
    -- never the money. A player who cannot afford the second would pass these
    -- assertions for a reason that has nothing to do with the rule.
    player(40, { balance = 5000 })
    buy(40, 'runner')
    ok(#buysOf(40) == 1 and buysOf(40)[1].row == 'runner',
        'a purchase is recorded against the player who made it')

    -- ═══ THE STAMP IS GONE, AND ITS ABSENCE IS ASSERTED ═══
    --
    -- `matchId` fed the carry-over accounting and nothing else. With carry-over
    -- gone it would be written and never read -- dead bookkeeping, which is the
    -- defect this project ships most often. It must not come back as a field
    -- that quietly means nothing.
    ok(buysOf(40)[1].matchId == nil,
        'and carries no match stamp -- the record cannot outlive its match, so '
            .. 'there is nothing for a stamp to distinguish',
        tostring(buysOf(40)[1].matchId))

    -- ═══ THE CONSOLE IS THE ONLY WITNESS, SO THE CONSOLE IS CAPTURED ═══
    --
    -- A forfeit is invisible from inside the game: no toast, no car, a balance
    -- that simply went down. The owner asked for a line he can point at if this
    -- turns out to feel wrong in play, and a line nobody asserts is a line that
    -- gets deleted in a tidy-up. `print` is swapped out so the emission itself
    -- is under test rather than its source text.
    local printed = {}
    local function capture(fn)
        local real = print
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            printed[#printed + 1] = table.concat(parts, ' ')
        end
        local okRun, err = pcall(fn)
        print = real
        if not okRun then error(err, 0) end
    end
    local function saidThat(pat)
        for _, line in ipairs(printed) do
            if line:find(pat) then return line end
        end
        return nil
    end

    printed = {}
    capture(function() BR.Shop.release(40) end)
    ok(#buysOf(40) == 0,
        'LEAVING THE MATCH DESTROYS IT -- he forfeits the car, and no record '
            .. 'survives to be handed over in a later round', #buysOf(40))
    ok(#charged == 1,
        'and nothing is given back: forfeit, not refund', #charged)
    ok(BR.Market.balances[40] == 5000 - 750,
        'the Volts stay spent -- 750 gone for a car he will never receive',
        BR.Market.balances[40])

    -- THE LINE, WITH THE CAR AND THE PRICE ON IT. Both matter: "somebody
    -- forfeited something" is not evidence, and the price is the number he
    -- would be weighing up if he decides this is too harsh.
    ok(saidThat('FORFEITED') ~= nil,
        'and it says so on the console, which is the only place it is visible '
            .. 'at all', table.concat(printed, ' | '))
    ok(saidThat('runner') ~= nil and saidThat('750') ~= nil,
        'naming the car and what it cost', table.concat(printed, ' | '))

    -- ...AND WHEELS-UP HANDS HIM NOTHING, which is the whole point of the
    -- ruling: the previous behaviour delivered this car in the next round.
    BR.Shop.deliver(matches[1])
    ok(inv[40] == nil,
        'so the next wheels-up he attends hands him nothing at all',
        inv[40] and #inv[40] or 'no inventory')

    -- ...AND HE MAY BUY AGAIN, because he is holding nothing. The ceiling must
    -- not become a lifetime ban on the strength of a car that no longer exists.
    reset()
    player(46, { balance = 5000 })
    buy(46, 'runner')
    BR.Shop.release(46)
    buy(46, 'hauler')
    ok(#charged == 2 and #buysOf(46) == 1 and buysOf(46)[1].row == 'hauler',
        'and having forfeited it he can buy another -- the ceiling is one at a '
            .. 'time, not one forever', #charged)

    -- ═══ FORFEIT ON LEAVING, NEVER FORFEIT WHILE STILL IN THE MATCH ═══
    --
    -- THE BOUNDARY THAT MATTERS MOST, and the failure the owner reported first:
    -- a paid car disappearing while he still had every right to it. Walking off
    -- the pad, driving to the far end of it, standing still for a minute -- none
    -- of those is leaving the match, and none of them may cost him the car.
    --
    -- What makes that true is that BR.Shop.release is reached from
    -- BR.Match.leaveMatch and from nowhere else: nothing in server/shop.lua
    -- reads a position or a distance, so there is no path from "moved" to
    -- "forfeited". This drives everything a player can do SHORT of leaving and
    -- then checks the car still arrives.
    reset()
    player(47)
    buy(47, 'runner')
    peds[47].x, peds[47].y = 900.0, -900.0    -- wandered right off the pad
    roster[47].pos = { x = 900.0, y = -900.0, z = 30.0 }
    ok(#buysOf(47) == 1,
        'wandering off the pad costs him nothing -- he is still in the match',
        #buysOf(47))
    BR.Shop.deliver(matches[1])
    ok(inv[47] ~= nil and #inv[47] == 1 and inv[47][1].item == 'car_runner',
        'and the car he paid for still arrives at wheels-up',
        inv[47] and #inv[47] or 0)

    -- ...AND THE FORFEIT ITSELF CANNOT LEARN WHERE ANYBODY IS STANDING. A
    -- distance check inside BR.Shop.release is exactly how "forfeit on leaving"
    -- would become "forfeit while standing in the match", so its absence is the
    -- assertion. Scoped to the FUNCTION: this file legitimately measures
    -- elsewhere -- the load-time spacing warning compares two catalogue rows,
    -- and BR.Shop.unpack reads a ped to know where to put a car -- and a
    -- file-wide ban would be a false positive on both.
    local srvF = (readFile(RES .. 'br_core/server/shop.lua')
                    :gsub('%-%-[^\n]*', ''))
    local releaseBody = srvF:match('function BR%.Shop%.release%(src%)(.-)\nend')
    ok(releaseBody ~= nil,
        'BR.Shop.release is findable, so the assertion below means something')
    ok(releaseBody ~= nil and releaseBody:find('BR%.Dist') == nil
           and releaseBody:find('GetEntityCoords') == nil
           and releaseBody:find('%.pos') == nil,
        'the forfeit reads no position and no distance, so there is no path '
            .. 'from "moved" to "forfeited"',
        releaseBody and releaseBody:gsub('%s+', ' ') or 'no body')

    -- ═══ AND IT IS REACHED FROM EXACTLY ONE DOOR ═══
    --
    -- The call site IS the rule. If a second caller ever appears -- a storm
    -- tick, a cull sweep, a disconnect handler that fires on a timeout -- then
    -- "leaving forfeits" silently becomes something else, and no assertion
    -- inside this file would notice.
    local callers = {}
    for _, f in ipairs({ 'br_core/server/match.lua', 'br_core/server/shop.lua',
                         'br_core/server/roster.lua', 'br_core/server/party.lua',
                         'br_core/server/players.lua', 'br_core/server/lobby.lua',
                         'br_core/server/main.lua' }) do
        -- THE DEFINITION IS NOT A CALL. `function BR.Shop.release(src)` matches
        -- the same pattern, so it is removed before counting -- otherwise
        -- server/shop.lua declaring the function reads as a second door.
        local body = (readFile(RES .. f):gsub('%-%-[^\n]*', '')
                                        :gsub('function%s+BR%.Shop%.release', ''))
        for _ in body:gmatch('BR%.Shop%.release%(') do
            callers[#callers + 1] = f
        end
    end
    ok(#callers == 1 and callers[1] == 'br_core/server/match.lua',
        'and BR.Shop.release is called from server/match.lua alone -- leaving '
            .. 'the match is the only door to a forfeit',
        table.concat(callers, ', '))
    local mtc3 = readFile(RES .. 'br_core/server/match.lua')
    ok(mtc3:find('function BR%.Match%.leaveMatch') ~= nil
           and mtc3:find('BR%.Shop%.release%(src%)') ~= nil,
        'and that call is inside BR.Match.leaveMatch')

    -- ═══ A SURPLUS IS DESTROYED RATHER THAN CARRIED ═══
    --
    -- Unreachable through the handler, so it is built by hand: two undelivered
    -- entries on one roster entry, which is the state the FIRST fix could
    -- produce. Wheels-up hands over ONE. The other is not kept for later -- that
    -- was the reading the owner overruled -- it is destroyed with the rest.
    reset()
    player(45)
    roster[45].shopBuys = {
        { row = 'runner', paid = 750, delivered = false },
        { row = 'hauler', paid = 400, delivered = false },
    }
    BR.Shop.deliver(matches[1])
    ok(inv[45] ~= nil and #inv[45] == 1 and inv[45][1].item == 'car_runner',
        'two undelivered cars produce ONE car at wheels-up, the older of them',
        inv[45] and #inv[45] or 0)
    ok(#buysOf(45) == 0,
        'and the other is destroyed rather than waiting for the next round',
        #buysOf(45))
    ok(#dropped == 0,
        'and nothing was quietly dropped on the floor to make the count work')

    BR.Shop.deliver(matches[1])
    ok(inv[45] ~= nil and #inv[45] == 1,
        'so a second wheels-up hands over nothing -- there is nothing left',
        inv[45] and #inv[45] or 0)

    -- ═══ A CHARGE THAT LANDS AFTER ITS MATCH IS FORFEITED, NOT BANKED ═══
    --
    -- THE ONE PATH BY WHICH "LEAVING FORFEITS" COULD BE TRUE EVERYWHERE ELSE AND
    -- STILL LEAK A CAR ACROSS ROUNDS. A DynamoDB round trip is up to six seconds
    -- and BR.Shop.release runs the instant a player leaves -- so a write that
    -- answers afterwards would write a record into an empty list, with nothing
    -- left to destroy it, and the next match's wheels-up would hand it over.
    -- That is precisely what he forbade.
    reset()
    player(48, { balance = 5000 })
    BR.Market.hold = true
    buy(48, 'runner')
    BR.Shop.release(48)                      -- he walks out mid-round-trip
    matches[1].state = BR.MatchState.PLAYING  -- ...and the warmup is over
    printed = {}
    capture(settleCharges)
    ok(#charged == 1, 'the money still left the row -- the write had landed',
        #charged)
    ok(saidThat('FORFEITED') ~= nil and saidThat('750') ~= nil,
        'and this forfeit is on the console too, with its price -- it is the '
            .. 'quietest one of the lot and the easiest to never notice',
        table.concat(printed, ' | '))
    ok(#buysOf(48) == 0,
        'but no record is written for a purchase that can no longer belong to a '
            .. 'live warmup -- it is forfeited on the spot rather than banked '
            .. 'for the next round', #buysOf(48))
    ok(#sent == 0 and #notices == 0,
        'and he is promised neither a car nor a toast for it',
        ('%d events, %d toasts'):format(#sent, #notices))

    -- A DELIVERED PURCHASE DOES NOT SURVIVE A RELEASE EITHER: its only job was
    -- to say "already bought this match".
    reset()
    player(41)
    buy(41, 'runner')
    BR.Shop.deliver(matches[1])
    BR.Shop.release(41)
    ok(#buysOf(41) == 0, 'nothing is carried out of a match that delivered it')

    -- RELEASING SOMEBODY WHO NEVER BOUGHT ANYTHING IS A NO-OP, not an error --
    -- BR.Match.leaveMatch calls this on every exit from every state.
    reset()
    player(42)
    BR.Shop.release(42)
    BR.Shop.release(43)          -- not on the roster at all
    ok(#buysOf(42) == 0, 'and a player who bought nothing releases nothing')

    -- ═══ THE CALL SITE, WHICH IS THE HALF A UNIT TEST CANNOT REACH ═══
    local mtc2 = readFile(RES .. 'br_core/server/match.lua')
    ok(mtc2:find('BR%.Shop%.release%(src%)') ~= nil,
        'and BR.Match.leaveMatch is what releases it -- the fix is wired to '
            .. 'the door he actually walked out of')
end

-- ---------------------------------------------------------------------------
describe('delivery')
-- ---------------------------------------------------------------------------
do
    reset()
    player(20)
    player(21)
    buy(20, 'runner')

    BR.Shop.deliver(matches[1])

    ok(inv[20] ~= nil and #inv[20] == 1
           and inv[20][1].item == 'car_runner'
           and inv[20][1].kind == BR.ItemKind.CONSUMABLE
           and inv[20][1].count == 1,
        'the buyer gets exactly one car item when the match starts')
    ok(inv[21] == nil, 'and the player who bought nothing gets nothing')

    -- ═══ AND IT ARRIVES SILENTLY ═══
    --
    -- Owner, 2026-08-29: "when transitioning to state BUS, the pickup sound is
    -- heard again by anyone who has purchased an item."
    --
    -- Every arrival in an inventory plays GTA's PICK_UP, which is right for
    -- something you walked over and wrong for a car you paid for during warmup
    -- and that the match hands you in the plane. The purchase already made that
    -- noise, at the moment the Volts left the balance.
    --
    -- ASSERTED ON THE OPTIONS PASSED TO give, which is where the decision is.
    -- The client's half of it -- that a marked push is actually silent, and
    -- that an unmarked one is not -- is tools/test_client.lua's.
    ok(lastGive ~= nil and type(lastGive.opts) == 'table'
           and lastGive.opts.quiet == true,
        'the car is delivered QUIETLY -- no pickup cue at wheels-up for '
            .. 'something bought minutes earlier',
        lastGive and tostring(lastGive.opts) or 'never called')

    -- ONCE. A delivery that ran twice would be two cars for one payment.
    BR.Shop.deliver(matches[1])
    ok(#inv[20] == 1, 'delivering twice delivers once', #inv[20])

    -- ═══ AND IT IS DROPPED AT THEIR FEET IF THE BAG IS FULL (answer 4) ═══
    reset()
    player(22)
    buy(22, 'runner')
    inv[22] = { 1, 2, 3, 4, 5 }        -- five slots, all taken
    BR.Shop.deliver(matches[1])
    ok(#dropped == 1 and dropped[1].src == 22
           and dropped[1].stack.item == 'car_runner',
        'a full inventory puts the car on the ground rather than losing it')

    -- ═══ THE ORDERING IN match.onEnter(BUS) ═══
    --
    -- Unobservable in game: one line the wrong way round and the purchase
    -- silently never arrives, which looks exactly like the purchase failing.
    local mtc = readFile(RES .. 'br_core/server/match.lua')
    local wipe = mtc:find('BR%.Inv%.clearFor%(m%)')
    local hand = mtc:find('BR%.Shop%.deliver%(m%)')
    ok(wipe ~= nil and hand ~= nil and hand > wipe,
        'the car is handed out AFTER the warmup inventory wipe, or the wipe '
            .. 'deletes the thing the player paid for')

    local busAt = mtc:find('elseif state == BR%.MatchState%.BUS then')
    local playAt = mtc:find('elseif state == BR%.MatchState%.PLAYING then')
    ok(busAt ~= nil and playAt ~= nil and hand > busAt and hand < playAt,
        'and it happens on the BUS transition -- "once the match starts"')
end

-- ---------------------------------------------------------------------------
describe('unpacking, and the absence of a refund')
-- ---------------------------------------------------------------------------
do
    reset()
    player(30)
    peds[30].heading = 0.0

    ok(BR.Shop.unpack(30, 'runner') == true, 'using the item builds the car')
    ok(#spawned == 1 and spawned[1].model == 'sultan'
           and spawned[1].vtype == 'automobile' and spawned[1].forSrc == 30,
        'through BR.Vehicles.spawnOwned, in the buyer\'s routing bucket')
    ok(math.abs(spawned[1].y - 5.0) < 0.001 and math.abs(spawned[1].x) < 0.001,
        'five metres in front of them rather than on top of them',
        spawned[1].x .. ' / ' .. spawned[1].y)
    ok(math.abs(spawned[1].heading - peds[30].heading) < 0.001,
        'facing the way they are facing, because they are about to be sitting '
            .. 'in it')

    local dress = nil
    for _, s in ipairs(sent) do if s.name == 'br:shop:dress' then dress = s end end
    ok(dress ~= nil and dress.src == 30 and dress.payload.row == 'runner'
           and dress.payload.n == 9001,
        'and the client is handed a net id and a CATALOGUE ID')

    -- THE WIRE CARRIES NOTHING ELSE. Two keys: the id and the row.
    local keys = 0
    for _ in pairs(dress.payload) do keys = keys + 1 end
    ok(keys == 2, 'those two things and nothing else', keys)

    -- ═══ A VANISHED CAR GETS NOTHING (answer 3) ═══
    reset()
    player(31)
    spawnFails = true
    ok(BR.Shop.unpack(31, 'runner') == false,
        'a spawn the engine refuses answers false')
    ok(#dropped == 0 and (inv[31] == nil or #inv[31] == 0),
        'and NOTHING is given back -- no refund, no replacement item')
    ok(#charged == 0, 'and no Volts are returned either')

    local none = nil
    for _, s in ipairs(sent) do if s.name == 'br:shop:dress' then none = s end end
    ok(none == nil, 'and no client is told to dress a car that does not exist')

    -- AN ITEM FOR A ROW THAT NO LONGER EXISTS.
    reset()
    player(32)
    ok(BR.Shop.unpack(32, 'nonesuch') == false and #spawned == 0,
        'and an item naming a row that is gone builds nothing')

    -- ═══ THE ITEM IS SPENT BEFORE THE SPAWN IS ATTEMPTED ═══
    --
    -- server/inventory.lua consumes the stack and THEN asks the shop, which is
    -- the opposite of the ambulance's ordering and is deliberate: a use that put
    -- the item back on a failed spawn is a use a player repeats until the engine
    -- cooperates, which is a second car for one payment.
    local invsrc = readFile(RES .. 'br_core/server/inventory.lua')
    local consume = invsrc:find('s%.count = s%.count %- 1')
    local ask = invsrc:find('BR%.Shop%.unpack')
    ok(consume ~= nil and ask ~= nil and ask > consume,
        'the slot is emptied before BR.Shop.unpack is called')
end

-- ---------------------------------------------------------------------------
describe('the dropped token')
-- ---------------------------------------------------------------------------
do
    -- The marker fallback is a client render decision and cannot be driven from
    -- here, so this asserts the two halves that make it reachable: that a
    -- failed prop is LATCHED, and that the latch is what the renderer reads.
    local lootsrc = readFile(RES .. 'br_core/client/loot.lua')

    ok(lootsrc:find('local function fallbackMarkerOf', 1, true) ~= nil,
        'client/loot.lua knows how to look a fallback marker up')
    ok(lootsrc:find('noProp%(e, .the engine refused to build it as an object.')
           ~= nil,
        'and marks an entry whose prop the engine would not build')
    ok(lootsrc:find('not isTrue%(IsModelValid%(model%)%)') ~= nil,
        'and one whose model this build does not have -- through isTrue, '
            .. 'because 0 IS TRUTHY and a raw read would never fire')
    ok(lootsrc:find('e%.noProp and fallbackMarkerOf%(e%)') ~= nil,
        'and the renderer draws that marker in place of the rarity disc')

    -- ═══ 34 WAS A HELICOPTER, AND HE READ IT OFF HIS OWN SCREEN ═══
    --
    -- Owner, 2026-08-30: "When I drop the marshall why does it use a 3dmarker
    -- instead of the model of the prop? It's also a helicopter marker, not a
    -- vehicle...." and "Also the marker 34 issue, yeah. That should be marker
    -- 36."
    --
    -- 34 was his own number, taken on trust, and this suite used to assert only
    -- that it was the one he named -- which is exactly how a wrong number
    -- survives a test. It is 36 now, MarkerTypeCarSymbol, and it is his number
    -- again; what changed is that one of them has been seen.
    ok(shipped.tokenMarker == 36,
        'the fallback marker is 36, the car glyph -- 34 was a helicopter and he '
            .. 'saw it', shipped.tokenMarker)
    ok(shipped.tokenMarker ~= 34,
        'and specifically not 34 any more, which is the value a revert puts back')

    -- AND IT REACHES THE ITEM, not just the config. The registered entry is
    -- what client/loot.lua actually reads at the moment a prop fails.
    local mk = BR.Config.ConsumableById['car_marshall']
    ok(mk ~= nil and mk.fallbackMarker == 36,
        'and it reaches the registered item, which is what the renderer reads',
        mk and mk.fallbackMarker or 'unregistered')

    -- ═══ AND THE FLOATING TOKEN IS LOWERED BY A NAMED NUMBER ═══
    --
    -- Owner, 2026-08-30: "At rest, the vehicle pickup props are floating above
    -- the ground at waist-level... The prop pickup should be lowered by maybe
    -- 0.5m." "Maybe" is an estimate by eye, so it is a knob he can turn rather
    -- than a literal at the draw site.
    ok(type(shipped.tokenDropM) == 'number' and shipped.tokenDropM > 0.0,
        'the dropped token has a lowering, in metres', tostring(shipped.tokenDropM))
    ok(shipped.tokenDropM == 0.5, 'and it is the 0.5m he named', shipped.tokenDropM)
    ok(mk ~= nil and mk.propDrop == 0.5,
        'which reaches the registered item beside its scale',
        mk and tostring(mk.propDrop) or 'unregistered')

    -- ═══ AND IT REACHES NOTHING ELSE ON THE MAP, WHICH IS THE POINT OF IT
    --     BEING PER-ITEM ═══
    --
    -- The same PlaceObjectOnGroundProperly settles every rifle, bandage and
    -- ammo box in the world. None of those is floating and none was reported
    -- as such; a lowering that reached them would bury about 1300 items.
    local buried = {}
    for id, c in pairs(BR.Config.ConsumableById) do
        if tonumber(c.propDrop or 0) > 0.0 and not id:find('^car_') then
            buried[#buried + 1] = id
        end
    end
    table.sort(buried)
    ok(#buried == 0,
        'and not one non-vehicle consumable is lowered with it',
        table.concat(buried, ', '))

    -- ...AND THE CLIENT APPLIES IT PER ENTRY, THROUGH THE LOOKUP. A literal in
    -- the spawn pass would be the same drop on every prop in the game.
    ok(lootsrc:find('local function propDropOf') ~= nil,
        'client/loot.lua looks the lowering up per entry')
    local drops = 0
    for _ in lootsrc:gmatch('propDropOf') do drops = drops + 1 end
    ok(drops >= 2, 'and CALLS it rather than merely defining it', drops)

    -- THE BODY, NOT JUST THE NAME. A propDropOf that returned a constant would
    -- satisfy both assertions above and lower every rifle on the map with it --
    -- which is the failure the per-item design exists to prevent, and it is
    -- invisible from the config side because the config would still be right.
    local dropBody = lootsrc:match('local function propDropOf%(e%)(.-)\nend')
    ok(dropBody ~= nil and dropBody:find('ConsumableById', 1, true) ~= nil
           and dropBody:find('c%.propDrop') ~= nil,
        'and answers from the ITEM rather than from a constant, so a rifle and '
            .. 'a car token cannot share a correction',
        dropBody and dropBody:gsub('%s+', ' ') or 'no body')

    -- THE RESTING HEIGHT MOVES WITH IT, which is the half that would otherwise
    -- put the float straight back: restZ is what the hover animation rises from
    -- and returns to, so lowering the object without lowering restZ would last
    -- until the first time somebody walked past.
    ok(lootsrc:find('e%.restZ = c%.z %- drop') ~= nil,
        'and the remembered resting height is the lowered one, so the hover '
            .. 'does not put the float back on its way down')
end

-- ---------------------------------------------------------------------------
describe('the sound and the words')
-- ---------------------------------------------------------------------------
do
    -- ═══ NO NEW AUDIO CUE ═══
    --
    -- config/audio.lua's rule: two actions that sound identical are worse than
    -- one that sounds wrong. A purchase IS something landing in an inventory,
    -- so it is the pickup cue and there is nothing new to audition.
    local cli = readFile(RES .. 'br_core/client/shop.lua')

    -- ═══ THE SAME TABLE, NOT A SECOND PAIR ═══
    --
    -- The cue is installed by BR.Config.Shop.register as a REFERENCE to
    -- BR.Config.Loot.pickupSound. `==` on tables is identity in Lua, so this
    -- fails the day somebody "tidies" it into a copy -- which is the edit that
    -- would let the two drift the next time the owner re-points the pickup
    -- sound.
    ok(shipped.cue == 'shop.buy',
        'the shipped config names one cue key')
    ok(BR.Config.Audio.cues['shop.buy'] == BR.Config.Loot.pickupSound,
        'and the shop cue IS BR.Config.Loot.pickupSound -- the same table, not '
            .. 'a copy of its two strings')
    ok(BR.Config.Loot.pickupSound.name == 'PICK_UP'
           and BR.Config.Loot.pickupSound.set == 'HUD_FRONTEND_DEFAULT_SOUNDSET',
        'which is PICK_UP / HUD_FRONTEND_DEFAULT_SOUNDSET')

    -- ═══ REACHED BY KEY, SO /brsfx CAN AUDITION IT ═══
    --
    -- tools/verify.sh refuses a set/name pair written at a call site outside
    -- three files; this is the positive form of that rule.
    ok(cli:find('BR%.Sfx%.play%(S%.cue%)') ~= nil,
        'and the client plays it by cue KEY rather than by naming the pair')
    ok(cli:find('PlaySoundFrontend') == nil
           and cli:find('PlaySoundFromEntity') == nil,
        'client/shop.lua names no audio native at all')

    -- ═══ THREE STRINGS, AND THE OWNER WROTE ALL OF THEM ═══
    --
    -- His standing rule is that unrequested copy reads as slop. The toast and
    -- the plate are quoted verbatim; the price is a bare number.
    ok(BR.Config.Shop.boughtToast ==
        'Thanks for your purchase. It will be available in your inventory '
        .. 'once the match starts.',
        'the toast, verbatim')

    -- ═══ AND THE BALANCE SENTENCE HE DICTATED (#239) ═══
    --
    -- "stated as 'Your new balance is: [X] Volts.'" -- the colon and the full
    -- stop are his, and `[X] Volts` is one placeholder for the figure and the
    -- word together, which is what priceLine already builds. One `%s`, not a
    -- `%d` and a second `%s`: a two-slot template would put the space between
    -- number and word in this string as well as in priceLine, and the two would
    -- drift the day the currency is renamed.
    ok(shipped.balanceToast == 'Your new balance is: %s.',
        'the balance sentence, verbatim, with one slot',
        shipped.balanceToast)
    ok(BR.ShopSolve.boughtToast(shipped, 250, 'Volts') ==
        'Thanks for your purchase. It will be available in your inventory '
        .. 'once the match starts. Your new balance is: 250 Volts.',
        'and the two are joined into one toast, in his order')
    ok(BR.ShopSolve.boughtToast(shipped, 250.9, 'Volts')
           :find('250 Volts', 1, true) ~= nil,
        'the figure is floored, like every other Volts figure in the game')
    ok(BR.ShopSolve.boughtToast(shipped, 0, 'Volts')
           :find('is: 0 Volts%.') ~= nil,
        'a balance of nothing still reads as a number rather than as a blank')

    -- THE CURRENCY WORD IS NOT IN EITHER STRING. config/market.lua spells it
    -- once; the toast gets it through priceLine like the plate does.
    ok(shipped.balanceToast:find('Volts', 1, true) == nil,
        'and the word "Volts" is not written in the template')
    ok(BR.ShopSolve.boughtToast(shipped, 250, nil)
           :find('250.', 1, true) ~= nil,
        'so with no currency name to be had the balance is a bare number, the '
            .. 'same way the plate\'s price is')

    -- ═══ A TEMPLATE THAT WILL NOT TAKE A STRING COSTS THE SENTENCE, NOT THE
    --     PURCHASE ═══
    --
    -- string.format throws on `%d` given a string, and this runs inside the
    -- charge callback -- AFTER the money has left the row. An authoring slip
    -- must not be the thing that makes a paid-for car fail to record.
    ok(BR.ShopSolve.boughtToast(
           { boughtToast = 'Bought.', balanceToast = 'Left: %d.' }, 250, 'Volts')
       == 'Bought.',
        'a template that cannot take the figure loses the second sentence and '
            .. 'nothing else -- it does not throw inside the charge callback')
    ok(BR.ShopSolve.boughtToast({ boughtToast = 'Bought.' }, 250, 'Volts')
       == 'Bought.',
        'and a config with no balance sentence at all is the toast on its own')
    ok(BR.Config.Shop.signLabel == '%s for sale',
        'and the plate says "[model name] for sale"')
    ok(BR.Config.Shop.signLabel:format('Sultan') == 'Sultan for sale',
        'which with a name in it reads the way he wrote it')

    -- ═══ THE PRICE, AND THE ONE WORD HE ASKED FOR ═══
    --
    -- Owner, 2026-08-29: 'Change the green line to say "x Volts"'. It was a bare
    -- number until he said that, and the word is the ONLY thing added -- no
    -- verb, no "press E to buy" of our own invention.
    ok(BR.ShopSolve.priceLine(750, 'Volts') == '750 Volts',
        'the plate\'s second line is the amount and then the currency word')
    ok(BR.ShopSolve.priceLine(750.9, 'Volts') == '750 Volts',
        'floored, because a balance is an integer everywhere it is shown')
    ok(BR.ShopSolve.priceLine(750, nil) == '750',
        'and with no currency name to be had it stays a bare number rather '
            .. 'than trailing an empty word')

    -- ═══ THE WORD IS NOT IN THE CLIENT FILE ═══
    --
    -- config/market.lua's `currency` is where that string lives, and its own
    -- comment says renaming the currency is that line plus the matching constant
    -- in Ringmaster. A literal in client/shop.lua would make it three places,
    -- and the third would be the one nobody greps.
    ok(cli:find("'Volts'", 1, true) == nil and cli:find('"Volts"', 1, true) == nil,
        'client/shop.lua contains no Volts STRING LITERAL -- the owner\'s '
            .. 'quoted instruction in a comment is not one')
    ok(cli:find('hint%s*=%s*BR%.ShopSolve%.priceLine') ~= nil,
        'the plate\'s second line is built by br_lib, from the row\'s price')
    ok(cli:find('BR%.Config%.Market') ~= nil,
        'and the word itself comes out of config, where it lives once')
    ok(BR.Config.Market.currency == 'Volts',
        'and config still calls it Volts, which is what the plate will read')

    -- NOTHING ELSE IS SPOKEN. Every notify/refuse this feature can reach is
    -- either the toast or the market's own existing sentence.
    local srv = readFile(RES .. 'br_core/server/shop.lua')
    local speaks = 0
    for _ in srv:gmatch('BR%.Server%.notify%(') do speaks = speaks + 1 end
    ok(speaks == 1,
        'server/shop.lua says exactly one thing to a player, and it is his '
            .. 'sentence', speaks)
end

-- ---------------------------------------------------------------------------
describe('the plate hangs at the bumper, and the bumper is the model\'s')
-- ---------------------------------------------------------------------------
do
    -- ═══ TWO BOXES, AND THEY ARE THE REASON ONE NUMBER COULD NOT WORK ═══
    --
    -- Owner, 2026-08-29: "change the DUI to draw at the elevation of the
    -- vehicle's bumper."
    --
    -- THESE FIGURES ARE REPRESENTATIVE, NOT MEASURED. GetModelDimensions needs a
    -- running game, so what is under test here is the ARITHMETIC over a box, and
    -- the boxes below are a small bike and a large truck to within a few
    -- centimetres. The property being asserted is not "the sanchez lands at
    -- 0.41" -- it is that a taller model gets a higher plate, that both land low
    -- on their own body, and that no single constant could have done either.
    local SANCHEZ_LO, SANCHEZ_HI = -0.55, 0.63   -- a dirt bike, ~1.18m tall
    local MARSHALL_LO, MARSHALL_HI = -1.55, 1.75 -- a monster truck, ~3.3m tall

    -- THE SHIPPED CONFIG, not the fixture standing in for it above: these two
    -- numbers are the tuning the owner will actually reach for.
    local F = shipped.signBumperFrac
    local L = shipped.signLift

    local sanchez  = BR.ShopSolve.signHeight(SANCHEZ_LO, SANCHEZ_HI, F, L)
    local marshall = BR.ShopSolve.signHeight(MARSHALL_LO, MARSHALL_HI, F, L)

    -- Heights ABOVE THE GROUND THE TYRES STAND ON, which is what "the elevation
    -- of the bumper" means to a person looking at the car. The function answers
    -- in model-origin space because that is what the native offset wants.
    local sanchezUp  = sanchez - SANCHEZ_LO
    local marshallUp = marshall - MARSHALL_LO

    ok(sanchezUp > 0.3 and sanchezUp < 0.6,
        'a sanchez wears its plate about 40cm off the ground',
        ('%.3f'):format(sanchezUp))
    ok(marshallUp > 0.9 and marshallUp < 1.4,
        'and a marshall wears its own more than a metre up',
        ('%.3f'):format(marshallUp))
    ok(marshallUp - sanchezUp > 0.5,
        'which is most of a metre apart -- the gap no single authored lift '
            .. 'could straddle',
        ('%.3f'):format(marshallUp - sanchezUp))

    -- ═══ THE DEFECT, STATED AS AN ASSERTION ═══
    --
    -- `signLift` was 1.15 above the ORIGIN. On a sanchez that is above the roof
    -- by half a metre: the plate floated in the air over the bike.
    ok(1.15 > SANCHEZ_HI,
        'the old fixed 1.15 was above a sanchez\'s roof outright',
        ('roof %.2f'):format(SANCHEZ_HI))
    ok(sanchez < SANCHEZ_HI and sanchez > SANCHEZ_LO,
        'and the derived height is inside the bike\'s own body')
    ok(marshall < MARSHALL_HI and marshall > MARSHALL_LO,
        'as it is inside the truck\'s')

    -- LOW ON THE BODY, not halfway up it. A bumper is not a windscreen.
    ok(F > 0.0 and F < 0.5,
        'the fraction puts it in the lower half of the model', F)

    -- ═══ THE NUDGE HE KEEPS ═══
    ok(BR.ShopSolve.signHeight(SANCHEZ_LO, SANCHEZ_HI, F, 0.25) - sanchez > 0.249
       and BR.ShopSolve.signHeight(SANCHEZ_LO, SANCHEZ_HI, F, 0.25) - sanchez < 0.251,
        'and signLift still moves every plate by exactly its own metres')
    ok(L == 0.0,
        'shipping at zero, because the derivation is meant to be the answer',
        L)

    -- ═══ A MODEL THAT NEVER LOADED ═══
    --
    -- GetModelDimensions answers zeroes -- or the caller answers nil -- for a
    -- model that is not in memory. A plate at the origin is a plate somebody can
    -- see and report; a plate at nan is an invisible sprite and a silent bug.
    ok(BR.ShopSolve.signHeight(nil, nil, F, 0.0) == 0.0,
        'no box means no derivation, and the answer is the lift alone')
    ok(BR.ShopSolve.signHeight(nil, nil, F, 1.15) == 1.15,
        'which is still exactly the nudge and nothing else')
    ok(BR.ShopSolve.signHeight(MARSHALL_HI, MARSHALL_LO, F, L) == marshall,
        'and a box handed over upside down produces the same height as the '
            .. 'right way up')

    -- THE CLIENT ASKS br_lib FOR IT rather than doing the arithmetic itself --
    -- the same rule that moved `nearest` out of client/shop.lua.
    local cli3 = readFile(RES .. 'br_core/client/shop.lua')
    ok(cli3:find('BR%.ShopSolve%.signHeight') ~= nil,
        'client/shop.lua derives the height through br_lib')
    ok(cli3:find('GetModelDimensions', 1, true) ~= nil,
        'off GetModelDimensions, which is the model\'s own box')
    -- THE VALUE, NOT THE WORD. The comment above signPoint quotes the old 1.15
    -- to say why it went; what must not survive is a fallback that reinstates it
    -- the moment config is missing a key.
    ok(cli3:find('signLift[^\n]*1%.15') == nil
           and cli3:find('or%s+1%.15') == nil,
        'and no fallback in the client puts the old fixed 1.15 back')
end

-- ---------------------------------------------------------------------------
describe('the showroom')
-- ---------------------------------------------------------------------------
do
    local cli = readFile(RES .. 'br_core/client/shop.lua')

    -- ═══ THE OWNER'S THREE WORDS ═══
    ok(cli:find('SetVehicleDoorsLocked', 1, true) ~= nil,
        'the display cars have their doors locked')
    ok(cli:find('SetEntityInvincible', 1, true) ~= nil,
        'are invincible')
    ok(cli:find('FreezeEntityPosition', 1, true) ~= nil,
        'and have their position frozen')

    -- ═══ ...AND INVINCIBLE DOES NOT COVER THE GLASS ═══
    --
    -- Owner, 2026-08-29: "we can break windshields by shooting them at the
    -- store. I thought they were [invincible]."
    --
    -- SET_ENTITY_INVINCIBLE is a health flag. Windows, deformation and scratches
    -- are the separate visible-damage system and tyres are a third one -- which
    -- this repository already knew from the other direction, since
    -- client/rescue.lua has to call SetVehicleTyresCanBurst explicitly on an
    -- ambulance that is deliberately NOT invincible.
    ok(cli:find('SetVehicleCanBeVisiblyDamaged') ~= nil,
        'so the display cars also refuse VISIBLE damage -- the glass, which is '
            .. 'the thing he shot')
    ok(cli:find('SetVehicleCanBeVisiblyDamaged,%s*veh,%s*false') ~= nil,
        'and refuse it FALSE, because the value is the whole of the fix')
    ok(cli:find('SetEntityProofs') ~= nil,
        'with the damage proofs on top, so nothing flinches or catches fire')
    ok(cli:find('SetVehicleTyresCanBurst,%s*veh,%s*false') ~= nil,
        'and tyres that cannot be shot out, which is a third system again')

    -- ═══ AND THE GLASS IS A FOURTH SYSTEM, WHICH IS THE ASSERTION aafe22a
    --     DID NOT MAKE ═══
    --
    -- Owner, 2026-08-30: "showroom glass STILL shatters." The previous fix
    -- reasoned that windows belong to the visible-damage system and stopped
    -- there; every assertion in this block stayed green while he shot a
    -- windscreen out, because they all agreed with the belief rather than
    -- testing it.
    --
    -- SO THE BELIEF IS WRITTEN DOWN AS A REQUIREMENT NOW. Vehicle glass has its
    -- own collision and its own native
    -- (_SET_DISABLE_VEHICLE_WINDOW_COLLISIONS, 0x1087BC8EC540DAEB), and this
    -- suite requires a call to it. Delete the call in the belief that
    -- SetVehicleCanBeVisiblyDamaged covers the windows -- which is precisely
    -- the mistake that shipped -- and the suite says so instead of the owner.
    --
    -- COMMENTS STRIPPED, AND THAT MATTERS MORE HERE THAN ANYWHERE ELSE IN THIS
    -- FILE. The note above the call cites the native by name, by hash and by
    -- source file -- which is the whole point of it -- so a bare match would go
    -- on passing with the call itself deleted and only the prose left behind.
    local code = (cli:gsub('%-%-[^\n]*', ''))
    ok(code:find('SetDisableVehicleWindowCollisions') ~= nil,
        'the glass has a system and a native of its own, and the showroom '
            .. 'CALLS it -- visible damage is deformation and paint, and '
            .. 'believing it covered the windows is what shipped twice')
    -- THE VALUE, BECAUSE true DISABLES THE COLLISION AND false RESTORES IT.
    -- `false` reads as the fix and undoes it, and no other assertion here can
    -- tell the two apart.
    ok(code:find('SetDisableVehicleWindowCollisions,%s*veh,%s*true') ~= nil,
        'and disables it TRUE, which is the direction that stops the breakage')

    -- ═══ FOUR SYSTEMS, FOUR CALLS, AND NONE OF THEM STANDING IN FOR ANOTHER
    --     ═══
    --
    -- The failure this whole issue is made of is one native being trusted to
    -- cover a system it does not own. So the four are listed once, here, and
    -- each is required in its own right: a future edit that drops one because
    -- "the proofs already do that" fails on the name it dropped.
    local SYSTEMS = {
        { native = 'SetEntityInvincible',           system = 'health' },
        { native = 'SetVehicleCanBeVisiblyDamaged', system = 'deformation and paint' },
        { native = 'SetVehicleTyresCanBurst',       system = 'tyres' },
        { native = 'SetDisableVehicleWindowCollisions', system = 'glass' },
    }
    for _, s in ipairs(SYSTEMS) do
        ok(code:find(s.native, 1, true) ~= nil,
            ('the showroom answers the %s system with a call of its own (%s)')
                :format(s.system, s.native))
    end

    -- ═══ AND NONE OF IT REACHES THE CAR HE BUYS ═══
    --
    -- #224: "After that it is an ordinary car: it burns fuel, it can be
    -- destroyed, anyone can steal it." BR.Shop.dress is the ONE function both
    -- the showroom car and the delivered car go through, so a protection that
    -- landed in it would follow the purchase into the match -- an indestructible
    -- car in a battle royale, which is a far worse bug than breakable glass.
    local dressFrom = cli:find('function BR%.Shop%.dress')
    local dressTo = cli:find('\nlocal ', dressFrom or 1) or #cli
    local dress = cli:sub(dressFrom or 1, dressTo)
    local PROTECTIONS = {
        'SetVehicleCanBeVisiblyDamaged', 'SetEntityProofs',
        'SetVehicleTyresCanBurst', 'SetEntityInvincible',
        'SetDisableVehicleWindowCollisions',
        'FreezeEntityPosition', 'SetVehicleDoorsLocked',
    }
    for _, native in ipairs(PROTECTIONS) do
        ok(dress:find(native, 1, true) == nil,
            ('BR.Shop.dress does not call %s -- it dresses, it does not '
             .. 'protect'):format(native))
    end

    -- ═══ AND NEITHER DOES THE DELIVERY, WHICH IS THE OTHER HALF OF THAT DOOR
    --     ═══
    --
    -- BR.Shop.dress is not the only code that touches the car a player drives
    -- away in: `br:shop:dress` adopts the net id, takes control and puts the
    -- buyer in the seat, and anything applied THERE follows the purchase into
    -- the match just as surely. An unbreakable, bulletproof car in a battle
    -- royale is a fighting advantage bought with Volts, which is the one thing
    -- the catalogue's entire safety argument exists to prevent -- and it is a
    -- far worse bug than the breakable glass this round is fixing.
    --
    -- COMMENTS STRIPPED, because that handler explains at length why the
    -- showroom's protections are not repeated in it, and naming them while
    -- saying so is exactly what this file should do.
    local delivFrom = cli:find("RegisterNetEvent('br:shop:dress')", 1, true)
    local delivTo = cli:find("AddEventHandler('onClientResourceStart'",
                             delivFrom or 1, true) or #cli
    local deliv = (cli:sub(delivFrom or 1, delivTo):gsub('%-%-[^\n]*', ''))
    ok(delivFrom ~= nil and delivTo > delivFrom,
        'the delivery handler is findable, so the assertions below mean '
            .. 'something', ('%s..%s'):format(tostring(delivFrom),
                                              tostring(delivTo)))
    for _, native in ipairs(PROTECTIONS) do
        ok(deliv:find(native, 1, true) == nil,
            ('nor does the delivery handler call %s -- once unpacked it is an '
             .. 'ordinary destructible car (#224)'):format(native))
    end
    ok(BR.Config.Shop.lockedState == 2,
        'lock state 2 (LOCKED), not 4 (LOCKED_PLAYER_INSIDE) -- 4 waits for an '
            .. 'entry that never happens and client/rescue.lua shipped it once')

    -- ═══ THE PLATE, AND THE BUG HIS SPACING TURNED FROM RARE INTO NORMAL ═══
    --
    -- `setPrompt` used to return early on `show == promptShown`, so the DUI
    -- payload -- the car's NAME and its PRICE -- was sent only when the plate
    -- came up. On a pad where the cars are 3.25m apart and the reach is five,
    -- walking down the line never drops the plate, so those words never changed:
    -- the sprite tracked the nearest car's bumper while the text still named the
    -- first car and quoted the first car's price. A player would read one price
    -- and be charged another.
    --
    -- The guard has to be on the PAIR -- shown, and shown for WHICH ROW.
    ok(cli:find('if show == promptShown and candidate == was then return end',
                1, true) ~= nil,
        'the plate re-sends when the nearest car changes, not only when it '
            .. 'appears -- otherwise the words name the car you walked away from')

    -- ...AND THE CHOICE OF CAR IS THE SHARED FUNCTION'S, NOT A LOOP IN HERE.
    -- The rule that decides whose Volts buy which car belongs somewhere a test
    -- can execute it; it used to be a private loop in this client file.
    ok(cli:find('BR%.ShopSolve%.nearest%(') ~= nil,
        'and the car is chosen by BR.ShopSolve.nearest, which this suite runs '
            .. 'against his real coordinates')

    -- ═══ THE FLOATING CARS: THE RIGHT NATIVE, IN THE RIGHT ORDER ═══
    --
    -- Owner, 2026-08-29: "sometimes the vehicles appear floating off the
    -- ground. Can we use PlaceObjectOnGroundProperly?"
    --
    -- That is the OBJECT native -- client/loot.lua settles crates with it and it
    -- does nothing to a vehicle. SET_VEHICLE_ON_GROUND_PROPERLY is the
    -- neighbouring one, and client/rescue.lua already uses it on the ambulance.
    local ground = cli:find('SetVehicleOnGroundProperly', 1, true)
    ok(ground ~= nil,
        'the showroom cars are settled with the VEHICLE grounding native')
    ok(cli:find('PlaceObjectOnGroundProperly%s*%(') == nil,
        'and not with the object one, which would silently do nothing to a car')

    -- ═══ AND THIS ORDERING TEST IS THE ONE THAT MATTERS ═══
    --
    -- A frozen entity does not move, so grounding AFTER the freeze pins every
    -- car at the height it was floating at and reports success -- the symptom
    -- is identical to not having called it at all, and it would be invisible to
    -- every other assertion in this file. client/loot.lua carries the same
    -- warning about its own props.
    --
    -- ═══ AND IT IS NOW A SANDWICH, BECAUSE THE COLLISION WAIT HOLDS THE CAR ═══
    --
    -- The wait added on 2026-08-31 is the only thing in the build that YIELDS,
    -- so it is the only point at which a new car gets a simulation step -- and
    -- a car handed to the physics over ground that has not streamed falls
    -- through the map. So it freezes the car for the duration, exactly the way
    -- client/loot.lua's awaitCollision does. THAT MAKES THE RELEASE
    -- LOAD-BEARING: leave the car frozen and the settle is the no-op this test
    -- was written about, with every other assertion in this file still green.
    --
    -- ON A COMMENT-STRIPPED COPY, and matching the ARGUMENTS rather than the
    -- native name -- both freezes are the same call and only the third
    -- parameter tells them apart. The last `veh, true` is the permanent one.
    --
    -- THE STRIP IS NOT OPTIONAL. This file explains the grounding at length,
    -- and names the native while doing so, hundreds of lines above the call --
    -- so a raw search finds the prose and compares the wrong two positions,
    -- which is how the assertion this replaces came to pass against a comment.
    local cliBody = (cli:gsub('%-%-[^\n]*', ''))
    local unfreeze = cliBody:find('FreezeEntityPosition, veh, false', 1, true)
    local groundC  = cliBody:find('SetVehicleOnGroundProperly', 1, true)
    local lastFreeze
    do
        local at = 1
        while true do
            local hit = cliBody:find('FreezeEntityPosition, veh, true', at, true)
            if not hit then break end
            lastFreeze, at = hit, hit + 1
        end
    end
    ok(unfreeze ~= nil and groundC ~= nil and unfreeze < groundC,
        'the car is UNFROZEN before it is grounded -- the collision wait holds '
            .. 'it, and a settle on a held car is a no-op that returns true',
        ('unfreeze@%s ground@%s'):format(tostring(unfreeze), tostring(groundC)))
    ok(groundC ~= nil and lastFreeze ~= nil and groundC < lastFreeze,
        'and the freeze that KEEPS it there comes after the grounding',
        ('ground@%s freeze@%s'):format(tostring(groundC), tostring(lastFreeze)))

    -- ═══ NOTHING SETTLES ONTO GROUND THAT HAS NOT ARRIVED (2026-08-31) ═══
    --
    -- Owner: "the positioning bug where vehicles are floating in the shop --
    -- that's still happening when going between buckets like `playing` to
    -- `warmup` [...] this will happen to players if they come back to warmup
    -- after a previous match."
    --
    -- The pad is built off the STATE FLIP to WARMUP, with the player still in
    -- the lobby 1.36km away and no collision resident under any row.
    -- SetVehicleOnGroundProperly needs ground to put wheels on, so until the
    -- wait existed whether a car landed correctly was a race against streaming
    -- -- `settled at build 12/13` cold, 0/13 on a rebuild.
    local await = cliBody:find('= awaitCollision(veh, row, mine)', 1, true)
    ok(await ~= nil,
        'each car waits for the world under it before anything settles it')
    ok(await ~= nil and groundC ~= nil and await < groundC,
        'and it waits BEFORE the settle, which is the whole of the fix',
        ('wait@%s ground@%s'):format(tostring(await), tostring(groundC)))

    -- BOTH QUESTIONS, AND BOTH THROUGH isTrue. They are wrong in opposite
    -- directions read raw: a truthy 0 from the first makes the wait a no-op
    -- that looks like it ran, and a truthy 0 from the second makes it never
    -- stop. `HasCollisionLoadedAroundEntity` alone is not enough either --
    -- an entity can report collision loaded while still queued behind it.
    ok(cli:find('isTrue(HasCollisionLoadedAroundEntity(veh))', 1, true) ~= nil,
        'the collision-loaded native is read through isTrue, because 0 is '
            .. 'truthy')
    ok(cli:find('isTrue(IsEntityWaitingForWorldCollision(veh))', 1, true) ~= nil,
        'and so is the still-waiting one, which would otherwise never let go')

    -- THE BUDGET IS A CONFIG VALUE, not a literal. A hardcoded ceiling is one
    -- nobody can nudge on the box where the fault actually reproduces.
    ok(cli:find('S%.collisionWaitMs') ~= nil,
        'the wait reads its ceiling out of the config under its own name')
    ok(type(shipped.collisionWaitMs) == 'number'
           and shipped.collisionWaitMs == 1500,
        'and the shipped ceiling is loot.lua\'s number, for loot.lua\'s reason',
        tostring(shipped.collisionWaitMs))

    -- AND THE ABANDONMENT CHECK SURVIVED THE REWRITE. The wait yields, so a
    -- state flap can start a second build while this one is holding a car that
    -- is in nobody's `cars` table -- teardown cannot reach it, and without this
    -- the pad leaks a frozen vehicle every time warmup flaps.
    ok(cliBody:find('if mine ~= gen then return done(false) end', 1, true) ~= nil,
        'a build that has been superseded stops waiting')
    -- SEARCHED FROM THE WAIT, NOT FROM THE TOP OF THE FILE. teardown() deletes
    -- entities too, several hundred lines earlier, so a search from 1 finds
    -- that one and passes no matter what the abandonment branch does -- which
    -- is what the first cut of this assertion did.
    local delAt = await and cliBody:find('DeleteEntity(veh)', await, true)
    ok(delAt ~= nil and groundC ~= nil and delAt < groundC,
        'and the car it was holding is deleted rather than orphaned -- it is '
            .. 'in nobody\'s `cars` table yet, so teardown cannot reach it',
        ('delete@%s ground@%s'):format(tostring(delAt), tostring(groundC)))

    -- IT RETURNS A BOOL, SO IT GOES THROUGH isTrue. Ten shipped instances of
    -- reading a native's 0 as truth on this project; this one would invert the
    -- fallback and leave a failed grounding unreported.
    ok(cli:find('isTrue(landed)', 1, true) ~= nil,
        'the grounding result is read through isTrue, because 0 is truthy')

    -- ═══ AND THE CARS START LOWER THAN HE SURVEYED THEM (#243) ═══
    --
    -- Owner, 2026-08-30: "After seeing the shop once in warmup, and going
    -- outside its focus area (cell/culling radius), then coming back, all the
    -- vehicles are floating off the ground again at waist level." And: "the same
    -- is true for the vehicles. That's all we need."
    ok(type(shipped.groundDropM) == 'number' and shipped.groundDropM == 0.5,
        'the showroom cars carry a 0.5m drop, the number he named',
        tostring(shipped.groundDropM))
    -- TWO FIELDS, TWO READERS. They hold the same 0.5 today, so no assertion on
    -- their VALUES can tell whether they are one knob or two -- what can is that
    -- each is read at its own site under its own name. Collapse them and the
    -- day he nudges the car and not the token, both move.
    ok(cli:find('S%.groundDropM') ~= nil,
        'the showroom reads its drop under its own name')
    ok(cli:find('tokenDropM') == nil,
        'and never the token\'s, so nudging one cannot move the other')

    -- ═══ APPLIED TO THE STARTING HEIGHT, AND NEVER TO HIS SURVEY ═══
    --
    -- "those coords are very specifically placed. Don't change them." The rows
    -- are untouched: the drop is subtracted at CreateVehicle, on top of the
    -- authored z, which this config has always called a starting height.
    ok(cli:find('local startZ = row%.z %+ 0%.0 %- %(tonumber%(S%.groundDropM%)')
           ~= nil,
        'the drop is subtracted from his authored z at spawn rather than edited '
            .. 'into the catalogue')
    for _, r in ipairs(SURVEY) do
        local model, _, _, z = table.unpack(r)
        local row = BR.ShopSolve.rowById(
            BR.ShopSolve.catalogue(shipped, shipped.refusedReason), model)
        ok(row ~= nil and row.z == z,
            model .. ': still stands at the z he surveyed, to the digit',
            row and row.z or 'no row')
    end

    -- ═══ AND IT IS SUBTRACTED BEFORE THE GROUNDING, NOT AFTER ═══
    --
    -- THE ORDERING THAT DECIDES WHETHER THIS FIXES ANYTHING OR BURIES
    -- EVERYTHING. SetVehicleOnGroundProperly puts the wheels on the surface;
    -- a drop applied AFTER a successful grounding would sink every car half a
    -- metre into the pad. Applied to the starting height it loses to the
    -- grounding whenever the grounding works -- which is what makes a first
    -- spawn unchanged -- and decides where a car comes back to when it does not.
    -- ON A COMMENT-STRIPPED COPY. The file explains the ordering at length and
    -- names the grounding native while doing so, hundreds of lines above the
    -- call -- so a raw search finds the prose and compares the wrong two
    -- positions.
    local cliCode2 = (cli:gsub('%-%-[^\n]*', ''))
    local dropAt = cliCode2:find('local startZ = row%.z')
    local groundAt = cliCode2:find('SetVehicleOnGroundProperly', 1, true)
    ok(dropAt ~= nil and groundAt ~= nil and dropAt < groundAt,
        'and it happens BEFORE the grounding -- after it, every car would be '
            .. 'buried half a metre rather than floating half a metre',
        ('drop@%s ground@%s'):format(tostring(dropAt), tostring(groundAt)))

    -- ═══ ...AND THE FALLBACK USES THE RAW SURVEY, WHICH IS THE OTHER HALF OF
    --     THE FIX (2026-08-31) ═══
    --
    -- IT USED THE DROPPED HEIGHT UNTIL TODAY, and it was wrong twice over in
    -- the same direction:
    --
    --   * `startZ` IS A STARTING HEIGHT FOR A SETTLE THAT HAS JUST REFUSED. The
    --     authored z is a settled car's ORIGIN -- config/shop.lua argues that
    --     from the thirteen numbers themselves -- so the height a car belongs
    --     at when the engine will not place it is that number exactly.
    --   * AND SET_ENTITY_COORDS LIFTS THE CAR BY ITS OWN HEIGHT, because it
    --     takes z as where the BOTTOM of the entity goes. Handed an origin
    --     height it produces an origin height plus a car, which is the
    --     floating.
    --
    -- A REJECTED FIX FOR THE SAME LINE PUT EVERY FAILED CAR 0.5m INTO THE
    -- GROUND, trading floating for sinking. The test for both is the same one:
    -- a failed car must stand where a successful settle would have left it.
    ok(cli:find('SetEntityCoordsNoOffset, veh, row%.x %+ 0%.0,\n'
                .. '%s*row%.y %+ 0%.0, row%.z %+ 0%.0, false, false, false%)')
           ~= nil,
        'the un-settled fallback places the car at the raw surveyed z, with '
            .. 'the native that does not add the car\'s own height to it')
    ok(cli:find('pcall(SetEntityCoords,', 1, true) == nil,
        'and never with the offsetting form, which would lift it by a whole '
            .. 'car body')
    ok(cli:find('startZ, false, false, false, false%)') == nil,
        'nor at the dropped starting height, which is a number no car the '
            .. 'engine refused was ever meant to rest at')

    -- ═══ THE VOLTS READOUT: A FLAG, NEVER A BALANCE ═══
    --
    -- Owner: "show their current volts balance with NUI where the bullet rounds
    -- show." br_ui already holds the figure -- it is what the Store screen
    -- renders -- so this side sends only whether the plate is up. A balance on
    -- this wire would be a second copy of one number, free to disagree with the
    -- shop screen.
    ok(cli:find("'shopplate'", 1, true) ~= nil,
        'the HUD is told when a plate goes up, so the Volts readout can follow')
    ok(cli:find("'shopplate', { show = show }", 1, true) ~= nil,
        'and no balance travels with it -- the payload is the flag and nothing '
            .. 'else, because the number is already in br_ui')

    -- ═══ THE PRICE: A FLAG, AND A COLOUR THAT IS NOT A HEX ═══
    --
    -- Owner: "the price text needs to be increased in font size and make it
    -- green. It should be large." -- and then, 2026-08-30, "the volts text
    -- should be orange - the same color we show in the market page". The colour
    -- must be a TOKEN resolved by the HUD's cascade either way, so a literal
    -- here would be the one colour in the game that ignored index.css.
    -- THE VALUE, NOT JUST THE FIELD. `hintBig = false` still contains the word
    -- "hintBig", and the plate would quietly go back to a 19px grey price with
    -- every other assertion here still green.
    ok(cli:find('hintBig%s*=%s*true') ~= nil,
        'the price asks the plate for its large treatment, and asks for it TRUE')
    ok(cli:find('BR%.Dui%.volts') ~= nil,
        'and takes its orange from the interface palette, resolved by br_ui')
    -- COMMENTS STRIPPED FIRST. The note above the field explains that the green
    -- went and names it while doing so; prose about a removed call is exactly
    -- what this file should contain, and matching it would make the assertion a
    -- ban on explaining the change.
    local cliCode = (cli:gsub('%-%-[^\n]*', ''))
    ok(cliCode:find('BR%.Dui%.hp') == nil,
        'and no longer CALLS the green, which is what it asked for until he '
            .. 'said otherwise -- a file that read both would paint whichever '
            .. 'one the last edit left in place')
    ok(cli:find('#%x%x%x%x%x%x') == nil,
        'with no hex colour written in this file at all')

    -- ...AND THE PAGE CLEARS THE TREATMENT ON EVERY MESSAGE. One browser serves
    -- five prompts; a page that only ever ADDED the price class would carry the
    -- shop's green into the next crate it drew, forever, because the DUI is
    -- never reloaded.
    local dui = readFile(RES .. 'br_ui/dui/prompt.html')
    ok(dui:find("hint.classList.remove('price')", 1, true) ~= nil,
        'and the shared prompt page clears the price treatment before each '
            .. 'message, so it cannot leak into the other four consumers')

    -- ═══ LOCAL, NEVER NETWORKED ═══
    --
    -- Two `false`s in the last two positions. A networked client-created vehicle
    -- is refused by sv_entityLockdown before any of our code runs, and the
    -- refusal is SILENT.
    ok(cli:find('false, false%)') ~= nil,
        'and they are created local and non-networked, like the Battle Bus')

    -- ...WHICH IS ALSO WHY THE VERIFY GATE IS NOT TRIPPED. Server-side vehicle
    -- creation is refused outside br_core/server/vehicles.lua; the showroom
    -- never asks for one.
    local srv = readFile(RES .. 'br_core/server/shop.lua')
    -- THE CALL, NOT THE WORD. tools/verify.sh matches
    -- `CreateVehicle(ServerSetter)?\s*\(` in any server file outside
    -- vehicles.lua, so the thing to assert absent is the CALL -- prose about
    -- why the call is not here is exactly what this file should contain.
    ok(srv:find('CreateVehicle%s*%(') == nil
           and srv:find('CreateVehicleServerSetter%s*%(') == nil,
        'server/shop.lua creates no vehicle itself -- it asks '
            .. 'BR.Vehicles.spawnOwned, which is where the allowlist lives')
    ok(srv:find('BR%.Vehicles%.spawnOwned') ~= nil,
        'and that is the only creation path it has')

    -- ONE BROWSER. A DUI is a whole CEF instance and this is the fifth consumer
    -- of the one prompt page, not a sixth browser.
    local pages = 0
    for _ in cli:gmatch('BR%.Dui%.page%(') do pages = pages + 1 end
    ok(pages == 1 and cli:find("'lootprompt'", 1, true) ~= nil,
        'and the plate borrows the one shared prompt page', pages)
end

-- ---------------------------------------------------------------------------
describe('the plate is a yard sign: stationary, level, squared to the car, in '
    .. 'metres')
-- ---------------------------------------------------------------------------
--
-- ═══ THIS BLOCK RUNS THE GEOMETRY RATHER THAN GREPPING FOR IT ═══
--
-- Owner, 2026-08-30: "The store DUIs are dynamically sized and face the player.
-- I want them to be stationary, with the DUI displayed on the front face of the
-- vehicle, akin to a yard sign."
--
-- Both faults were properties of BR.Dui.drawWorld, which is SetDrawOrigin +
-- DrawSprite: the origin projects a world point to the screen and the sprite is
-- then measured in SCREEN fractions. So it always squared itself to the camera
-- and it always held the same share of the display at every distance -- and
-- NEITHER of those is a parameter anybody could have passed differently. A
-- source assertion could only ever have checked that the call was still there.
--
-- So client/dui.lua is LOADED here, standing on a car with a real POSE -- a
-- heading, a pitch and a roll -- and the four corners it produces are read back
-- out of the DrawSpritePoly calls. Every assertion below fails against the old
-- drawWorld path: there are no polys at all to read.
--
-- THE POSE IS A FULL ONE BECAUSE A YAW-ONLY ONE WAS WHY THIS BLOCK WAS GREEN
-- WHILE THE SIGN WAS CROOKED (2026-08-30). The fixture used to rotate about Z
-- and nothing else, so it could not express a bike leaning on its kickstand and
-- it modelled the behaviour we wanted rather than the one the native has.
do
    -- --- the browser, exactly as tools/test_client.lua stubs it ------------
    json = { encode = function() return '{}' end }
    function CreateDui() return 7 end
    function CreateRuntimeTxd(n) return n end
    function CreateRuntimeTextureFromDuiHandle() end
    function GetDuiHandle() return 'h' end
    function IsDuiAvailable() return true end
    function SendDuiMessage() end
    function DestroyDui() end

    -- --- one car, at a known place, in a known ATTITUDE -------------------
    --
    -- GTA HEADING IS COUNTER-CLOCKWISE DEGREES FROM NORTH, so forward is
    -- (-sin h, cos h) and right is (cos h, sin h). Written out rather than
    -- taken from the code under test: a stub that shared the implementation's
    -- convention would agree with it however wrong both were.
    local CAR = { x = 100.0, y = 200.0, z = 30.0,
                  h = 0.0, pitch = 0.0, roll = 0.0 }
    local VEH = 4242

    function DoesEntityExist(e) return e == VEH end

    --- The car's three body axes -- right, forward, up -- in WORLD coordinates.
    ---
    --- BUILT FROM THE PHYSICS, NOT FROM AN EULER CONVENTION THE ENGINE NAMES.
    --- GET_ENTITY_ROTATION's rotationOrder argument (this repo asks for 2,
    --- ROT_ZXY) decides how a triple of angles composes, and the Cfx docs
    --- describe the enum only as "rotate around z-axis, then x-axis, then
    --- y-axis" -- not enough to lift into a fixture that is meant to be the
    --- independent party. So the pose is composed here from what the words
    --- mean instead: start from the world-aligned car (right = +X, forward =
    --- +Y, up = +Z), ROLL it about its own forward axis, PITCH it about its own
    --- right axis, then swing it to its heading about the WORLD's up.
    ---
    --- Two consequences, and the fix under test leans on the first while this
    --- block exists to pin the second:
    ---   * a pure roll leaves FORWARD exactly alone, because a rotation cannot
    ---     move the axis it turns about -- which is why a sign that wants to
    ---     ignore a kickstand lean needs no angles, only the forward vector;
    ---   * a pure roll moves RIGHT and UP by the roll angle, so any quad spanned
    ---     by those two -- which is what the sign used to be -- tilts with it.
    --- @return table right, table fwd, table up
    local function axes()
        local ch, sh = math.cos(math.rad(CAR.h)), math.sin(math.rad(CAR.h))
        local cp, sp = math.cos(math.rad(CAR.pitch)), math.sin(math.rad(CAR.pitch))
        local cr, sr = math.cos(math.rad(CAR.roll)), math.sin(math.rad(CAR.roll))
        local function body(vx, vy, vz)
            vx, vz = vx * cr + vz * sr, vz * cr - vx * sr   -- roll,  about +Y
            vy, vz = vy * cp - vz * sp, vy * sp + vz * cp   -- pitch, about +X
            vx, vy = vx * ch - vy * sh, vx * sh + vy * ch   -- yaw,   about +Z
            return { vx, vy, vz }
        end
        return body(1.0, 0.0, 0.0), body(0.0, 1.0, 0.0), body(0.0, 0.0, 1.0)
    end

    -- THE THREE ENTITY READS, ALL OFF THAT ONE POSE. Sharing a source is the
    -- point: a fixture whose position, matrix and forward vector could disagree
    -- would let a wrong fix pass by quietly reading a different car.
    --
    -- GetEntityCoords ADDS the car to this file's ped lookup rather than
    -- replacing it -- every server-side block above reads that table, and a
    -- stub answering {0,0,0} for a ped would break them silently if this block
    -- ever moved.
    local pedCoords = GetEntityCoords
    function GetEntityCoords(e)
        if e == VEH then return { x = CAR.x, y = CAR.y, z = CAR.z } end
        return pedCoords(e)
    end
    function GetEntityForwardVector(e)
        if e ~= VEH then return { x = 0.0, y = 1.0, z = 0.0 } end
        local _, fwd = axes()
        return { x = fwd[1], y = fwd[2], z = fwd[3] }
    end
    --- An offset in the car's own frame, through the car's whole matrix. This
    --- is what drawFace used to be built on and what drawOnEntity still is.
    function GetOffsetFromEntityInWorldCoords(e, lx, ly, lz)
        local rt, fwd, up = axes()
        return {
            x = CAR.x + rt[1] * lx + fwd[1] * ly + up[1] * lz,
            y = CAR.y + rt[2] * lx + fwd[2] * ly + up[2] * lz,
            z = CAR.z + rt[3] * lx + fwd[3] * ly + up[3] * lz,
        }
    end

    local cam = { x = 100.0, y = 210.0, z = 31.0 }
    function GetGameplayCamCoord() return cam end

    --- Every triangle drawn since the last clear, as { v = {3 vertices},
    --- uv = {3 pairs} }.
    local polys = {}
    function DrawSpritePoly(x1, y1, z1, x2, y2, z2, x3, y3, z3,
                            _r, _g, _b, _a, _txd, _tex,
                            u1, v1, _w1, u2, v2, _w2, u3, v3, _w3)
        polys[#polys + 1] = {
            v  = { { x1, y1, z1 }, { x2, y2, z2 }, { x3, y3, z3 } },
            uv = { { u1, v1 }, { u2, v2 }, { u3, v3 } },
        }
    end

    -- THE BILLBOARD NATIVES ARE DEFINED AND MUST NEVER FIRE. If drawFace ever
    -- reaches for SetDrawOrigin it is a billboard again, whatever else it does.
    local originDraws = 0
    function SetDrawOrigin() originDraws = originDraws + 1 end
    function DrawSprite() originDraws = originDraws + 1 end
    function ClearDrawOrigin() end
    function GetAspectRatio() return 1.7778 end
    function GetActiveScreenResolution() return 1920, 1080 end

    loadCore('br_core/client/dui.lua')

    local page = BR.Dui.page('signprobe', 'nui://br_ui/dui/prompt.html', 512, 256)
    -- `shipped`, NOT BR.Config.Shop: the fixture catalogue was swapped in above
    -- and carries no geometry. These numbers are the ones the owner will reach
    -- for, so they are the ones under test.
    local W = shipped.signWidthM

    local function draw(oy, oz)
        polys = {}
        BR.Dui.drawFace(page, VEH, oy, oz, W)
        return polys
    end

    --- The vertex carrying a given UV, from whichever triangle holds it.
    local function at(uv0, uv1)
        for _, p in ipairs(polys) do
            for i = 1, 3 do
                if p.uv[i][1] == uv0 and p.uv[i][2] == uv1 then return p.v[i] end
            end
        end
        return nil
    end

    local function near(a, b, tol)
        return math.abs(a - b) <= (tol or 0.0005)
    end
    local function samePoint(p, q)
        return p ~= nil and q ~= nil
            and near(p[1], q[1]) and near(p[2], q[2]) and near(p[3], q[3])
    end

    -- ═══ 1. IT DRAWS AT ALL, AND IT DRAWS A QUAD ═══
    local OY, OZ = 3.0, 0.6
    draw(OY, OZ)
    ok(#polys == 2, 'the sign is two triangles of world geometry', #polys)
    ok(originDraws == 0,
        'and not one SetDrawOrigin or DrawSprite -- the screen-space path, '
            .. 'which is what made it a billboard, is not reached at all',
        originDraws)

    local tl, tr = at(0.0, 0.0), at(1.0, 0.0)
    local bl, br = at(0.0, 1.0), at(1.0, 1.0)
    ok(tl and tr and bl and br,
        'and all four texture corners are placed')

    -- ═══ 2. IT IS MEASURED IN METRES ═══
    --
    -- The old plate was 0.144 of the SCREEN's width, which is not a length. The
    -- new one is signWidthM across and half that tall, because the page is
    -- 512x256 -- so the shape follows the texture and is not a second number.
    local function dist(p, q)
        local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    ok(near(dist(tl, tr), W, 0.001),
        ('the sign is exactly signWidthM (%.3fm) across'):format(W),
        ('%.4f'):format(dist(tl, tr)))
    ok(near(dist(tl, bl), W * 0.5, 0.001),
        'and half that tall, which is the 512x256 page\'s own aspect',
        ('%.4f'):format(dist(tl, bl)))

    -- ═══ 3. IT IS STATIONARY -- THE CAMERA CANNOT MOVE IT ═══
    --
    -- THE ASSERTION THE WHOLE ISSUE IS ABOUT. Walk right round the car and the
    -- four corners must not shift by a millimetre. A billboard fails this on
    -- every corner; so does anything that scales with distance.
    local before = { tl, tr, bl, br }
    cam = { x = 40.0, y = 90.0, z = 80.0 }      -- far away, and behind
    draw(OY, OZ)
    local after = { at(0.0, 0.0), at(1.0, 0.0), at(0.0, 1.0), at(1.0, 1.0) }
    local moved = 0
    for i = 1, 4 do
        if not samePoint(before[i], after[i]) then moved = moved + 1 end
    end
    ok(moved == 0,
        'moving the camera 130m and round to the far side moves no corner at '
            .. 'all -- the sign is stationary and is not dynamically sized',
        moved)
    ok(#polys == 2,
        'and it is still drawn from behind rather than vanishing -- the winding '
            .. 'swaps, the geometry does not', #polys)
    cam = { x = 100.0, y = 210.0, z = 31.0 }

    -- ═══ 4. IT IS WELDED TO THE CAR'S OWN HEADING ═══
    --
    -- Turn the car and the sign turns with it, because its width follows the
    -- car's forward vector. At heading 0 the sign stands across the world's X
    -- axis, in front of the car's nose; at heading 90 the same sign stands
    -- across Y. Section 7 is the other half of this: its heading and NOT its
    -- lean.
    draw(OY, OZ)
    local flat0 = math.abs(at(0.0, 0.0)[2] - at(1.0, 0.0)[2])
    ok(near(flat0, 0.0, 0.001),
        'facing north, the sign\'s width lies along world X and its two top '
            .. 'corners share a Y', ('%.4f'):format(flat0))
    ok(near(at(0.0, 0.0)[2], CAR.y + OY, 0.001),
        'and it stands OY metres in front of the car, on the car\'s own nose '
            .. 'line', ('%.3f'):format(at(0.0, 0.0)[2]))

    CAR.h = 90.0
    draw(OY, OZ)
    local flat90 = math.abs(at(0.0, 0.0)[1] - at(1.0, 0.0)[1])
    ok(near(flat90, 0.0, 0.001),
        'turn the car ninety degrees and the sign turns with it -- now the top '
            .. 'corners share an X instead', ('%.4f'):format(flat90))
    ok(near(at(0.0, 0.0)[1], CAR.x - OY, 0.001),
        'and it is still off the nose, which now points west',
        ('%.3f'):format(at(0.0, 0.0)[1]))
    CAR.h = 0.0

    -- ═══ 5. THE CENTRE IS THE POINT THE CALLER ASKED FOR ═══
    draw(OY, OZ)
    local cx = (at(0.0, 0.0)[1] + at(1.0, 1.0)[1]) * 0.5
    local cy = (at(0.0, 0.0)[2] + at(1.0, 1.0)[2]) * 0.5
    local cz = (at(0.0, 0.0)[3] + at(1.0, 1.0)[3]) * 0.5
    ok(near(cx, CAR.x, 0.001) and near(cy, CAR.y + OY, 0.001)
           and near(cz, CAR.z + OZ, 0.001),
        'the sign is centred on exactly the offset the shop hands over -- the '
            .. 'bumper height derivation is not quietly shifted by half a plate',
        ('%.3f %.3f %.3f'):format(cx, cy, cz))

    -- ═══ 6. AND IT IS NOT MIRROR WRITING ═══
    --
    -- THE ONE FAULT THAT RENDERS PERFECTLY. A reader stands in FRONT of the car
    -- looking back along its -Y; facing that way the car's +X is on their LEFT.
    -- So the texture's u=0 edge has to be at +X. Reverse it and the sign is
    -- flawless, legible, correctly placed, and back to front -- and no
    -- structural assertion anywhere can tell.
    draw(OY, OZ)
    ok(at(0.0, 0.0)[1] > at(1.0, 0.0)[1],
        'the texture\'s left edge sits on the reader\'s left, which is the '
            .. 'car\'s +X -- so the sign is not mirror writing',
        ('u0 at x=%.3f, u1 at x=%.3f'):format(at(0.0, 0.0)[1],
                                              at(1.0, 0.0)[1]))
    ok(at(0.0, 0.0)[3] > at(0.0, 1.0)[3],
        'and the texture\'s top edge is the higher one, so it is not upside '
            .. 'down either')

    -- ═══ 7. AND IT IS LEVEL, WHATEVER THE CAR IS DOING ═══
    --
    -- Owner, 2026-08-30: "The store DUIs look great - but can you make sure
    -- they're always drawn perfectly level? For example the sanchez tilts a bit
    -- on the kickstand, and now it's DUI tilts lol."
    --
    -- EVERY GEOMETRY ASSERTION BELOW FAILS AGAINST THE MATRIX VERSION, now that
    -- the fixture can express an attitude at all: at 25 degrees the top corners
    -- of a 0.75m sign sat 0.317m apart in height, on a sign only 0.375m tall.

    --- The sign's centre, off the two corners on a diagonal.
    local function centre()
        local p, q = at(0.0, 0.0), at(1.0, 1.0)
        return (p[1] + q[1]) * 0.5, (p[2] + q[2]) * 0.5, (p[3] + q[3]) * 0.5
    end

    -- FIRST, THAT THE FIXTURE CAN STILL TILT AT ALL. The version of this block
    -- that shipped the bug was green because its stub was yaw-only, and a stub
    -- that quietly lost its roll again would make everything below vacuous. So
    -- the matrix is asked directly: at 25 degrees a signWidthM-wide local
    -- X-by-Z rectangle really does drop one end by W*sin(roll).
    CAR.roll = 25.0
    local mL = GetOffsetFromEntityInWorldCoords(VEH,  W * 0.5, OY, OZ)
    local mR = GetOffsetFromEntityInWorldCoords(VEH, -W * 0.5, OY, OZ)
    ok(near(math.abs(mL.z - mR.z), W * math.sin(math.rad(25.0)), 0.001),
        'the fixture\'s matrix genuinely rolls: through it, the sign\'s own '
            .. 'width lands 0.317m out of level, which is what he was looking '
            .. 'at', ('%.4f'):format(math.abs(mL.z - mR.z)))
    CAR.roll, CAR.pitch = 0.0, 12.0
    local mT = GetOffsetFromEntityInWorldCoords(VEH, 0.0, OY, OZ + W * 0.25)
    local mB = GetOffsetFromEntityInWorldCoords(VEH, 0.0, OY, OZ - W * 0.25)
    ok(near(math.abs(mT.y - mB.y), W * 0.5 * math.sin(math.rad(12.0)), 0.001),
        'and it genuinely pitches: the sign\'s own height leans out of plumb '
            .. 'through the same matrix, so the pitch case below is not asking '
            .. 'a level car whether it is level',
        ('%.4f'):format(math.abs(mT.y - mB.y)))
    CAR.pitch = 0.0
    CAR.roll = 25.0


    draw(OY, OZ)
    local rtl, rtr = at(0.0, 0.0), at(1.0, 0.0)
    local rbl, rbr = at(0.0, 1.0), at(1.0, 1.0)
    ok(near(rtl[3], rtr[3], 0.0005),
        'a car rolled 25 degrees -- a bike down on its kickstand -- wears a '
            .. 'sign whose top edge is still dead level',
        ('%.4fm of drop'):format(math.abs(rtl[3] - rtr[3])))
    ok(near(rbl[3], rbr[3], 0.0005),
        'and so is its bottom edge',
        ('%.4fm of drop'):format(math.abs(rbl[3] - rbr[3])))
    ok(near(rtl[1], rbl[1], 0.0005) and near(rtl[2], rbl[2], 0.0005),
        'and its sides hang plumb, so the whole quad is level rather than just '
            .. 'the one edge that happens to lie across the lean')
    ok(near(dist(rtl, rtr), W, 0.001),
        'and it is still the full signWidthM across -- rebuilt level, not '
            .. 'squashed flat, which would leave W*cos(roll)',
        ('%.4f, flattened would be %.4f'):format(
            dist(rtl, rtr), W * math.cos(math.rad(25.0))))
    local lx, ly, lz = centre()
    ok(near(lx, CAR.x, 0.001) and near(ly, CAR.y + OY, 0.001)
           and near(lz, CAR.z + OZ, 0.001),
        'and the ANCHOR is levelled with it: the sign hangs on the car\'s own '
            .. 'centreline at the height the shop asked for, instead of being '
            .. 'swung out sideways by the lean it is refusing to copy',
        ('%.3f %.3f %.3f'):format(lx, ly, lz))
    CAR.roll = 0.0

    CAR.pitch = 12.0
    draw(OY, OZ)
    local ptl, pbl = at(0.0, 0.0), at(0.0, 1.0)
    ok(near(ptl[1], pbl[1], 0.0005) and near(ptl[2], pbl[2], 0.0005),
        'nose the car up twelve degrees and the sign still hangs plumb -- '
            .. '"perfectly level" is the pitch as well as the roll',
        ('%.4fm out of plumb'):format(
            math.sqrt((ptl[1] - pbl[1]) ^ 2 + (ptl[2] - pbl[2]) ^ 2)))
    local px, py, pz = centre()
    ok(near(px, CAR.x, 0.001) and near(py, CAR.y + OY, 0.001)
           and near(pz, CAR.z + OZ, 0.001),
        'and it stands OY along the ground and OZ above the origin, rather '
            .. 'than being lifted by the nose it is standing off',
        ('%.3f %.3f %.3f'):format(px, py, pz))
    CAR.pitch = 0.0

    -- THE SANCHEZ'S OWN ROW, because a sign that is only level facing north is
    -- level for the fixture and not for him. config/shop.lua authors that row
    -- at heading 197.7; the lean is the kickstand's.
    CAR.h, CAR.pitch, CAR.roll = 197.7, 3.0, 25.0
    draw(OY, OZ)
    local stl, str, sbl = at(0.0, 0.0), at(1.0, 0.0), at(0.0, 1.0)
    ok(near(stl[3], str[3], 0.0005) and near(stl[1], sbl[1], 0.0005)
           and near(stl[2], sbl[2], 0.0005),
        'at the heading his catalogue actually authors, leaning and nose-up, '
            .. 'the sign is level and plumb',
        ('%.4fm of drop'):format(math.abs(stl[3] - str[3])))

    local hr = math.rad(CAR.h)
    local fwx, fwy = -math.sin(hr), math.cos(hr)
    local sx, sy, sz = centre()
    ok(near(sx, CAR.x + fwx * OY, 0.001) and near(sy, CAR.y + fwy * OY, 0.001)
           and near(sz, CAR.z + OZ, 0.001),
        'and it stands off the nose along the heading the row authored, not '
            .. 'along wherever the leaning bodywork points',
        ('%.3f %.3f %.3f'):format(sx, sy, sz))
    ok(near((str[1] - stl[1]) * fwx + (str[2] - stl[2]) * fwy, 0.0, 0.001),
        'the sign\'s width is still square across that heading -- levelling it '
            .. 'did not turn it',
        ('%.4f'):format((str[1] - stl[1]) * fwx + (str[2] - stl[2]) * fwy))
    ok((stl[1] - str[1]) * math.cos(hr) + (stl[2] - str[2]) * math.sin(hr) > 0.0,
        'and the texture\'s left edge is still on the car\'s +X at a heading '
            .. 'that is not zero, so the rebuilt right vector did not come back '
            .. 'mirrored')
    CAR.h, CAR.pitch, CAR.roll = 0.0, 0.0, 0.0

    -- AND THE MATRIX IS GONE FROM THIS ONE FUNCTION ONLY. The geometry above
    -- would also pass if drawFace still went through the matrix and something
    -- downstream straightened the result; this says which native the sign is
    -- built on, and that the crate label keeps the one IT needs.
    local duiSrc = readFile(RES .. 'br_core/client/dui.lua')
    local faceBody =
        duiSrc:match('function BR%.Dui%.drawFace(.-)function BR%.Dui%.')
    local lidBody =
        duiSrc:match('function BR%.Dui%.drawOnEntity(.-)function BR%.Dui%.')
    ok(faceBody ~= nil
           and faceBody:find('GetOffsetFromEntityInWorldCoords') == nil,
        'the sign resolves no corner through the entity\'s matrix any more')
    ok(faceBody ~= nil and faceBody:find('GetEntityForwardVector') ~= nil,
        'it builds its own basis off the flattened forward vector instead, '
            .. 'which is the one axis a roll cannot move')
    ok(lidBody ~= nil
           and lidBody:find('GetOffsetFromEntityInWorldCoords') ~= nil,
        'while drawOnEntity keeps the whole matrix, pitch and roll included -- '
            .. 'a label stuck to a crate lid follows the lid down a slope '
            .. '(2026-08-06), and levelling that one would put a shipped bug '
            .. 'back')

    -- ═══ 8. THE CONFIG KNOB IS A LENGTH, AND THE SCREEN FRACTION IS GONE ═══
    ok(type(shipped.signWidthM) == 'number' and shipped.signWidthM > 0.0,
        'signWidthM is a width in metres', tostring(shipped.signWidthM))
    ok(shipped.signScale == nil,
        'and signScale -- a multiplier on a SCREEN fraction, which is the unit '
            .. 'that made the plate grow as he backed away -- no longer exists',
        tostring(shipped.signScale))

    local cli4 = readFile(RES .. 'br_core/client/shop.lua')
    ok(cli4:find('BR%.Dui%.drawFace%(') ~= nil,
        'the shop draws its plate with drawFace')
    ok(cli4:find('BR%.Dui%.drawWorld%(') == nil,
        'and never with drawWorld, which is the billboard it is replacing')

    -- ...AND THE OTHER FOUR CONSUMERS ARE UNTOUCHED. drawWorld is right for a
    -- prompt hanging over a crate; it was only ever wrong for a sign on a car.
    local dui = readFile(RES .. 'br_core/client/dui.lua')
    ok(dui:find('function BR%.Dui%.drawWorld') ~= nil,
        'drawWorld still exists for the crate, the pump, the revive and the '
            .. 'heal station')

    -- ═══ 9. THE TITLE, AND THE CURRENCY WORD'S CASE ═══
    ok(cli4:find('labelBig%s*=%s*true') ~= nil,
        'the plate asks for the vehicle name\'s larger treatment')

    local pg = readFile(RES .. 'br_ui/dui/prompt.html')
    ok(pg:find('#label%.big') ~= nil,
        'and the page defines it')
    ok(pg:find("label.classList.remove('big')", 1, true) ~= nil,
        'and clears it on every message, so it cannot leak into the four other '
            .. 'prompts sharing this browser')

    -- ═══ "VOLTS DOESN'T NEED TO BE ALL CAPS" ═══
    --
    -- #hint is `text-transform: uppercase`, and `.price` INHERITED it -- which
    -- is how config/market.lua's "Volts" reached his screen as "VOLTS". The
    -- fix is one declaration on the price rule, and it is the whole of it.
    local priceRule = pg:match('#hint%.price%s*{(.-)}')
    ok(priceRule ~= nil and priceRule:find('text%-transform:%s*none'),
        'the price line turns the uppercasing back off, so the currency word '
            .. 'is spelled the way config/market.lua spells it',
        priceRule and priceRule:gsub('%s+', ' ') or 'no rule')
    ok(BR.Config.Market.currency == 'Volts',
        'which is "Volts", in sentence case, and is still the only place it '
            .. 'is written', BR.Config.Market.currency)

    -- ═══ 10. THE ORANGE IS THE MARKET PAGE'S OWN TOKEN, END TO END ═══
    --
    -- Owner: "the same color we show in the market page". That is a claim about
    -- ONE TOKEN reaching two documents, and every link in the chain is checked
    -- here -- the Store screen paints with it, the settings apply reads it out
    -- of the resolved cascade, br_ui forwards it, br_core holds it, the shop
    -- sends it. A hex anywhere in that chain would satisfy "it looks orange"
    -- and fail this.
    local mkt = readFile('ui-src/src/screens/Market.tsx')
    local apply = readFile('ui-src/src/settings/apply.ts')
    local voltsToken = apply:match(
        "const volts = style%.getPropertyValue%('(%-%-[%w%-]+)'%)")
    ok(voltsToken ~= nil,
        'settings/apply.ts reads a named token for the currency colour',
        tostring(voltsToken))
    ok(voltsToken ~= nil and mkt:find('var(' .. voltsToken .. ')', 1, true) ~= nil,
        'and it is the very token the Store screen paints its balance and its '
            .. 'prices with -- "the same color we show in the market page", '
            .. 'proved rather than matched by eye', tostring(voltsToken))
    ok(apply:find('CB.PALETTE, { hp, volts }', 1, true) ~= nil,
        'both colours travel in one post, so the plate is never half repainted')

    local set = readFile(RES .. 'br_ui/client/settings.lua')
    ok(set:find('volts = volts', 1, true) ~= nil,
        'br_ui forwards it on br:settings:palette')
    ok(dui:find('function BR%.Dui%.volts') ~= nil
           and dui:find('p%.volts') ~= nil,
        'br_core holds it and offers it to the plate')
    ok(dui:find('#%x%x%x%x%x%x') == nil,
        'and client/dui.lua still writes no colour of its own')
end

-- ---------------------------------------------------------------------------
describe('/brshop -- the reading that replaces the guess (#243)')
-- ---------------------------------------------------------------------------

--- ═══ THIS BLOCK RUNS THE REAL client/shop.lua, IT DOES NOT READ IT ═══
---
--- Every other assertion about the client in this file is a search over its
--- source text, and a search cannot tell whether a printed column holds the
--- right number. The command under test exists to produce numbers the owner
--- will make a decision from, so it is STOOD UP AND CALLED here, against a
--- world whose ground, collision and settling behaviour this block decides --
--- which is the only way to check that a probe refusing to answer reads as a
--- refusal rather than as an answer of zero.
---
--- IT IS LAST IN THE FILE ON PURPOSE. Loading a client file installs its
--- handlers and overwrites several engine stubs the server blocks above share,
--- so nothing may run after it.
---
--- ═══ THE FIXTURE ENCODES THE THING THE CONSTANT CANNOT DO ═══
---
--- Three rows, three models, and THREE DIFFERENT ORIGIN-TO-WHEEL DISTANCES --
--- because that is the fault the owner is looking at ("some through the ground
--- but some are still floating") and a fixture where every model sat the same
--- height above its own origin could not express it. `far` additionally stands
--- 900m away with no collision and a ground probe that refuses, which is the
--- shape of the `veto` row.
do
    --- Where the ground is, whether the world is resident, and whether the
    --- settle will work -- per row, decided here rather than by the code.
    local WORLD = {
        near = { gz = 29.60, gzx = 29.60, coll = true,  settles = true  },
        -- gzx DIFFERS HERE, AND ONLY HERE. The two probes exclude different
        -- things, so a column that copied the other one instead of asking its
        -- own native would agree on all three rows; this row is what makes
        -- that copy fail.
        mid  = { gz = 29.60, gzx = 29.15, coll = true,  settles = true  },
        far  = { gz = nil,   gzx = nil,   coll = false, settles = false },
    }

    --- How far each model's origin stands above its own tyre contact patch.
    --- The whole argument against one authored drop, in three numbers.
    local WHEEL = { sultan = 0.65, bison = 1.10, blista = 0.55 }

    local DIAG = {
        enabled = true, limit = 1, reachM = 4.0, minSpacingM = 6.0,
        useMs = 3000, lockedState = 2, tokenScale = 0.1, tokenMarker = 34,
        spawnAheadM = 5.0,
        signLabel = shipped.signLabel, signWidthM = shipped.signWidthM,
        signForwardM = shipped.signForwardM,
        signBumperFrac = shipped.signBumperFrac, signLift = shipped.signLift,
        boughtToast = shipped.boughtToast, balanceToast = shipped.balanceToast,
        cue = shipped.cue,
        -- HIS NUMBER, UNCHANGED. This block asserts what the drop DOES, and
        -- zeroing it here would be asserting against a shop nobody runs.
        groundDropM = 0.5,
        -- ...AND DELIBERATELY NOT HIS. The shipped budget is 1500 and so is the
        -- client's `or` default, so a fixture that used either could not tell a
        -- client reading this key from one with the number typed into it. 250
        -- can only come from here.
        collisionWaitMs = 250,
        items = {
            { id = 'near', model = 'sultan', price = 750,
              x = 100.0, y = 200.0, z = 30.0, heading = 90.0 },
            { id = 'mid',  model = 'bison',  price = 400,
              x = 140.0, y = 200.0, z = 30.0, heading = 90.0 },
            { id = 'far',  model = 'blista', price = 100,
              x = 1000.0, y = 200.0, z = 30.0, heading = 0.0 },
        },
    }
    DIAG.register      = shipped.register
    DIAG.refusedReason = shipped.refusedReason
    BR.Config.Shop = DIAG

    --- Which row an authored x belongs to.
    local function rowAt(x)
        for _, it in ipairs(DIAG.items) do
            if math.abs(it.x - x) < 0.01 then return it.id end
        end
    end

    --- Every entity this block has made: [handle] = a car standing in a world.
    local ents = {}
    local byId = {}                 -- [row id] = handle
    local nextHandle = 9000
    --- Every ground probe fired, in order: { id, x, y, fromZ }.
    local probes = {}

    --- Natives that would MOVE, MAKE or DESTROY something. Recorded only while
    --- `armed` -- the build legitimately calls several of them, and the claim
    --- under test is about the COMMAND.
    local writes, armed = {}, false
    local function noteWrite(name)
        if armed then writes[#writes + 1] = name end
    end

    -- --- the engine --------------------------------------------------------

    function IsModelValid() return true end
    function IsModelAVehicle() return true end
    function RequestModel() end
    function HasModelLoaded() return true end
    function SetModelAsNoLongerNeeded() end
    function PlayerPedId() return 1 end

    local PLAYER = { x = 102.0, y = 200.0, z = 30.0 }

    function CreateVehicle(_model, x, y, z, h, _net, _mission)
        noteWrite('CreateVehicle')
        nextHandle = nextHandle + 1
        local id = rowAt(x)
        local model
        for _, r in ipairs(DIAG.items) do if r.id == id then model = r.model end end
        ents[nextHandle] = { id = id, model = model,
                             x = x, y = y, z = z, h = h,
                             pitch = 0.0, roll = 0.0 }
        byId[id] = nextHandle
        return nextHandle
    end

    local prevExists = DoesEntityExist
    function DoesEntityExist(e)
        if ents[e] then return 1 end
        return prevExists(e)
    end

    local prevCoords = GetEntityCoords
    function GetEntityCoords(e)
        if e == 1 then return { x = PLAYER.x, y = PLAYER.y, z = PLAYER.z } end
        local c = ents[e]
        if c then return { x = c.x, y = c.y, z = c.z } end
        -- A DEAD HANDLE THROWS, WHICH IS WHAT THE ENGINE DOES. client/shop.lua's
        -- own draw pass carries the note ("reading the coordinates of a dead
        -- handle throws"), and a stub that answered {0, 0, 0} instead would let
        -- an unguarded read pass while printing every lost car at sea level.
        if e >= 9000 then error('coords on a dead entity handle', 0) end
        return prevCoords(e)
    end

    function SetEntityCoords(e, x, y, z)
        noteWrite('SetEntityCoords')
        local c = ents[e]
        if c then c.x, c.y, c.z = x, y, z end
    end
    function SetEntityCoordsNoOffset(e, x, y, z)
        noteWrite('SetEntityCoordsNoOffset')
        local c = ents[e]
        if c then c.x, c.y, c.z = x, y, z end
    end
    --- FROZEN IS A STATE HERE, NOT A NO-OP, because the settle below has to be
    --- able to refuse the way the engine refuses. A stub that only recorded the
    --- call could not tell a build that grounds an unfrozen car from one that
    --- grounds a frozen one, and those two produce identical source text and
    --- opposite showrooms.
    function FreezeEntityPosition(e, on)
        noteWrite('FreezeEntityPosition')
        local c = ents[e]
        if c then c.frozen = (on == true or on == 1) end
    end
    function DeleteEntity(e) noteWrite('DeleteEntity') ents[e] = nil end
    function SetEntityRotation() noteWrite('SetEntityRotation') end
    function SetEntityHeading() noteWrite('SetEntityHeading') end
    function RequestCollisionAtCoord() noteWrite('RequestCollisionAtCoord') end
    function SetFocusPosAndVel() noteWrite('SetFocusPosAndVel') end

    --- The settle: the ENGINE's per-model answer, which is the ground plus that
    --- model's own origin-to-wheel distance and nothing the config authored.
    ---
    --- IT ANSWERS 1 AND 0, NOT true AND false. Both spellings are live in FiveM
    --- and 0 is truthy in Lua; a fixture that answered `false` could not catch
    --- the defect this project has shipped ten times.
    ---
    --- AND A FROZEN CAR IS PINNED WHERE IT IS, WHILE THE NATIVE STILL SAYS YES.
    --- That is the trap client/shop.lua warns about in two places -- "grounding
    --- after the freeze would pin each car at exactly the height it was
    --- floating at and report success" -- and it is now a fixture behaviour
    --- rather than a comment: freeze before this and `built` reads the CREATED
    --- height with `settled` still counting the car, which is precisely the
    --- symptom that would otherwise be invisible to every assertion here.
    function SetVehicleOnGroundProperly(e)
        noteWrite('SetVehicleOnGroundProperly')
        local c = ents[e]
        if not c then return 0 end
        if c.frozen then return 1 end
        local w = WORLD[c.id]
        if not w or not w.settles then return 0 end
        c.z = w.gz + WHEEL[c.model]
        return 1
    end

    function GetGroundZFor_3dCoord(x, y, fromZ, _water)
        local id = rowAt(x)
        probes[#probes + 1] = { id = id, x = x, y = y, fromZ = fromZ }
        local w = id and WORLD[id]
        -- A REFUSAL IS A ZERO, WHICH IS TRUTHY IN LUA. Cfx documents the native
        -- as answering false outside the client's render distance; this is that
        -- answer in the spelling that has cost this project the most.
        if not w or not w.gz then return 0 end
        return 1, w.gz
    end

    function GetGroundZExcludingObjectsFor_3dCoord(x, _y, _fromZ, _water)
        local id = rowAt(x)
        local w = id and WORLD[id]
        if not w or not w.gzx then return 0 end
        return 1, w.gzx
    end

    function HasCollisionLoadedAroundEntity(e)
        local c = ents[e]
        return (c and WORLD[c.id] and WORLD[c.id].coll) and 1 or 0
    end
    function IsEntityWaitingForWorldCollision(e)
        local c = ents[e]
        return (c and WORLD[c.id] and WORLD[c.id].coll) and 0 or 1
    end
    function IsVehicleOnAllWheels(e)
        local c = ents[e]
        return (c and WORLD[c.id] and WORLD[c.id].settles) and 1 or 0
    end

    --- The engine's own "how far off the ground is this", which owes nothing to
    --- the survey or to the drop. Zero for a car standing on its wheels.
    function GetEntityHeightAboveGround(e)
        local c = ents[e]
        if not c then return 0.0 end
        local w = WORLD[c.id]
        if not w or not w.gz then return 0.0 end
        return c.z - w.gz - WHEEL[c.model]
    end

    function GetEntityRotation(e)
        local c = ents[e]
        if not c then return { x = 0.0, y = 0.0, z = 0.0 } end
        return { x = c.pitch, y = c.roll, z = c.h }
    end

    Citizen = {
        Wait = function() end,
        -- SYNCHRONOUS, so the build finishes inside the call that starts it.
        CreateThread = function(f) f() end,
    }

    local commands = {}
    function RegisterCommand(n, fn) commands[n] = fn end

    local loops = {}
    BR.Loop = {
        SLOW = 'slow', TICK = 'tick', FRAME = 'frame',
        register = function(_, name, fn) loops[name] = fn end,
    }
    BR.Keys = { on = function() end, isHeld = function() return false end }
    BR.State = {
        me    = { state = BR.PlayerState.WARMUP },
        match = { state = BR.MatchState.WARMUP },
    }

    -- --- the subject -------------------------------------------------------

    local realPrint = print
    local out = {}
    local function quiet(f, ...)
        out = {}
        print = function(s) out[#out + 1] = tostring(s) end
        local fine, err = pcall(f, ...)
        print = realPrint
        return fine, err
    end

    loadCore('br_core/client/shop.lua')
    ok(commands['brshop'] ~= nil, '/brshop is registered on the client')

    -- BEFORE ANYTHING IS BUILT. A diagnostic that throws when there is nothing
    -- to diagnose is a diagnostic nobody gets to run on the fault.
    ok(quiet(commands['brshop'], nil, {}, ''),
        '/brshop does not throw with no catalogue and no pad')

    quiet(handlers['onClientResourceStart'], 'br_core')
    quiet(loops['shop.scene'])
    ok(byId.near and byId.mid and byId.far, 'the pad built three cars')

    --- One printed row, split into its columns.
    ---
    --- SPLIT ON WHITESPACE RATHER THAN MATCHED CHARACTER BY CHARACTER: the
    --- padding is a presentation choice and re-aligning a column must not go
    --- red, while a wrong VALUE in one must.
    local function cols(id)
        for _, line in ipairs(out) do
            if line:match('^%s*([%w_]+)') == id then
                local c = {}
                for tok in line:gmatch('%S+') do c[#c + 1] = tok end
                return {
                    id = c[1], model = c[2], survey = c[3], built = c[4],
                    now = c[5], dsrv = c[6], dblt = c[7],
                    gz = c[9], gzx = c[10], hgt = c[11],
                    coll = c[13], wait = c[14], whls = c[15],
                    -- THE SECOND COLLISION GROUP: the same two questions asked
                    -- AT THE BUILD, plus how long that car waited. The first
                    -- group is sampled when the command is typed, which is
                    -- minutes later and from the middle of the pad.
                    bcoll = c[17], bwait = c[18], bms = c[19], rot = c[21],
                }
            end
        end
        return nil
    end

    local function lineWith(s)
        for _, line in ipairs(out) do
            if line:find(s, 1, true) then return line end
        end
    end

    local function run()
        probes, writes = {}, {}
        armed = true
        local fine = quiet(commands['brshop'], nil, {}, '')
        armed = false
        return fine
    end

    ok(run(), '/brshop does not throw with the pad standing')

    -- ═══ 1. IT MEASURES AND IT NEVER PLACES ═══
    --
    -- THE ASSERTION THE WHOLE COMMIT RESTS ON. The owner has been told this
    -- round changes nothing about where a car ends up; a single write from the
    -- command would make that false, and it would be invisible on screen
    -- because the numbers would still look plausible.
    ok(#writes == 0,
        '/brshop calls no native that moves, makes or destroys anything',
        table.concat(writes, ', '))

    -- ═══ 2. A HEALTHY ROW ═══
    local near = cols('near')
    ok(near ~= nil, 'the near row prints a line')
    ok(near and near.model == 'sultan', 'naming its model', near and near.model)
    ok(near and near.survey == '30.00',
        'and the z the catalogue authored', near and near.survey)
    ok(near and near.built == '30.25' and near.now == '30.25',
        'built and now agree -- nothing has moved it since the settle',
        near and (near.built .. ' / ' .. near.now))
    ok(near and near.dblt == '0.00',
        'so the drift against its build height is zero', near and near.dblt)
    ok(near and near.hgt == '0.00' and near.whls == 'Y',
        'the engine says it is on the ground and on all its wheels',
        near and (near.hgt .. ' / ' .. near.whls))

    -- ═══ 3. THE SPLIT, WHICH IS THE FAULT HE IS LOOKING AT ═══
    --
    -- `mid` is a bison: its origin stands 1.10m over its own tyres against the
    -- sultan's 0.65. Both cars are ON THE GROUND and each is a different
    -- distance from the surveyed z, and `d-srv` is the column that says so.
    -- One authored constant cannot be both numbers, which is the whole of the
    -- argument the next round has to settle.
    local mid = cols('mid')
    ok(mid and near and mid.dsrv == '0.70' and near.dsrv == '0.25',
        'two settled cars sit two different distances from the same surveyed '
            .. 'height -- one constant cannot be right for both',
        mid and near and (mid.dsrv .. ' vs ' .. near.dsrv))
    ok(mid and mid.dblt == '0.00',
        'and neither has drifted, so this is a placement fault and not a '
            .. 'streaming one', mid and mid.dblt)

    -- ═══ 4. THE TWO PROBES ARE TWO QUESTIONS ═══
    ok(near and near.gz == '29.60' and near.gzx == '29.60',
        'where both probes agree, the surface under the car is map geometry',
        near and (near.gz .. ' / ' .. near.gzx))
    ok(mid and mid.gz == '29.60' and mid.gzx == '29.15',
        'and where they disagree the column says so -- the excluding-objects '
            .. 'probe is asked its own native, not copied from the first',
        mid and (mid.gz .. ' / ' .. mid.gzx))

    -- ═══ 5. THE veto CASE: A PROBE THAT REFUSES, IN THE SPELLING THAT LIES ═══
    --
    -- The native answers 0 for "outside the render distance" and 0 is TRUTHY in
    -- Lua. Read raw, this row would print a ground of 0.00 -- sea level on this
    -- map, a plausible-looking number -- and the one row that most needs to be
    -- recognised as unmeasurable would read as measured.
    local far = cols('far')
    ok(far and far.gz == 'NONE' and far.gzx == 'NONE',
        'a probe that refuses prints as a refusal, not as a ground of 0.00',
        far and (far.gz .. ' / ' .. far.gzx))
    ok(far and far.coll == 'N' and far.wait == 'Y',
        'and the collision columns say the world is not resident there',
        far and (far.coll .. ' / ' .. far.wait))
    -- ═══ AND THE UN-SETTLED CAR IS AT THE RAW SURVEY, NOT AT THE DROP ═══
    --
    -- IT READ 29.50 UNTIL 2026-08-31 and that was the bug, not the fixture. The
    -- authored z is a settled car's ORIGIN (config/shop.lua argues it from the
    -- thirteen numbers), so a car the engine would not place belongs at exactly
    -- that height -- the drop is a starting height for a settle that has just
    -- refused to happen, and SET_ENTITY_COORDS would then have lifted the car
    -- by its own height on top of it. Both faults pushed the same way, upward,
    -- into the floating this branch exists to prevent.
    ok(far and far.built == '30.00' and far.now == '30.00',
        'the un-settled car is at the z the catalogue authored, with nothing '
            .. 'added and nothing taken off', far and far.built)
    ok(far and far.dsrv == '0.00',
        'so it stands exactly where a settled car of its model would have, '
            .. 'rather than half a metre under it', far and far.dsrv)
    ok(far and far.whls == 'N', 'and it is not standing on its wheels',
        far and far.whls)

    -- ═══ AND THE BUILD-MOMENT COLUMNS SAY WHY IT DID NOT SETTLE ═══
    --
    -- THIS IS THE PAIR THE FIRST READING OF THIS COMMAND GOT WRONG. `coll` and
    -- `wait` above are asked when the command is TYPED; by then a player is
    -- standing on the pad and they say what a healthy pad says no matter what
    -- the world looked like when the cars were made. These three are that
    -- earlier moment, and only these three can distinguish "the ground was
    -- never there" from "the ground is there now".
    ok(near and near.bcoll == 'Y' and near.bwait == 'N' and near.bms == '0',
        'a car built into a world that was already resident waited for nothing',
        near and (near.bcoll .. '/' .. near.bwait .. '/' .. near.bms))
    ok(far and far.bcoll == 'N' and far.bwait == 'Y',
        'and the car that never settled records a world that never arrived, '
            .. 'while `coll`/`wait` on the same line are sampled now',
        far and (far.bcoll .. '/' .. far.bwait))
    -- 250 IS THE FIXTURE'S OWN BUDGET AND NOTHING ELSE IN THE TREE HOLDS IT.
    -- The shipped value and the client's `or` default are both 1500, so this is
    -- the only number that can prove the budget is READ rather than typed in.
    ok(far and far.bms == '250',
        'having spent the configured budget waiting for it, to the millisecond',
        far and far.bms)

    -- ═══ 5b. AND NOW THE WORLD ARRIVES, WHICH IS THE READING THAT MISLED ═══
    --
    -- THIS IS THE EXACT SHAPE OF THE OWNER'S OWN READOUT. The pad is built from
    -- the lobby, 1.36km out, over nothing; by the time he walks to the cars and
    -- types /brshop the collision is resident and `coll`/`wait` say so. Two
    -- rounds were spent looking for something that MOVED the cars because of
    -- it. Nothing moved them -- they were placed wrong, and the only columns
    -- that can say so are the ones taken at the build.
    --
    -- SO THE TWO GROUPS MUST DISAGREE ON THIS ROW. A `b-coll` copied from
    -- `coll` -- the cheapest way to write these columns wrong -- agrees with it
    -- on every row in every other case in this file, and only here does it not.
    WORLD.far.coll = true
    run()
    local far2 = cols('far')
    ok(far2 and far2.coll == 'Y' and far2.wait == 'N',
        'the world under the un-settled car has streamed in since, and the '
            .. 'live columns say so', far2 and (far2.coll .. '/' .. far2.wait))
    ok(far2 and far2.bcoll == 'N' and far2.bwait == 'Y' and far2.bms == '250',
        'while the build columns still say it was made over nothing -- which '
            .. 'is the whole reason they are kept rather than sampled',
        far2 and (far2.bcoll .. '/' .. far2.bwait .. '/' .. far2.bms))
    ok(far2 and far2.built == '30.00' and far2.dblt == '0.00',
        'and the car has still not moved -- a collision that arrives late does '
            .. 'not re-settle a frozen car, which is why the placement has to '
            .. 'be right the first time', far2 and far2.dblt)

    -- ═══ 6. THE PROBE STARTS ABOVE THE SURFACE ═══
    --
    -- "A probe started under the surface can only answer with something lower
    -- or with nothing at all" -- client/loot.lua, written after hillside loot
    -- spawned below the map. A future edit that starts this one at the surveyed
    -- z, or at the dropped z, re-opens that exact hole.
    local pNear
    for _, pr in ipairs(probes) do if pr.id == 'near' then pNear = pr end end
    ok(pNear ~= nil and pNear.fromZ > 30.0,
        'the ground probe starts ABOVE the surveyed z, never at or below it',
        pNear and pNear.fromZ)
    ok(pNear ~= nil and pNear.x == 100.0 and pNear.y == 200.0,
        'and it is fired at the coordinate he surveyed', pNear and pNear.x)

    -- ═══ 7. THE HEADER LABELS THE READING ═══
    --
    -- A printout taken from across the island is a printout of a world that is
    -- not loaded, and every NONE in it means nothing. The distance line is what
    -- lets the second reading of the pair be recognised as one taken on the way
    -- back rather than one taken at the cars.
    local head = lineWith('nearest row')
    ok(head ~= nil, 'the header carries a distance line')
    ok(head ~= nil and head:find('nearest row near at 2.0m', 1, true) ~= nil,
        'naming the nearest row and how far the player is from it', head)
    ok(head ~= nil and head:find('farthest far at 898.0m', 1, true) ~= nil,
        'and the farthest, so an outlier row cannot hide behind an average',
        head)

    -- ═══ 8. THE VERDICT LINE ═══
    local verdict = lineWith('settled at build')
    ok(verdict ~= nil and verdict:find('settled at build 2/3', 1, true) ~= nil,
        'the summary counts what the engine grounded', verdict)
    ok(verdict ~= nil
           and verdict:find('probe answering now 2/3', 1, true) ~= nil,
        'and how much of the world is answering right now', verdict)
    ok(verdict ~= nil and verdict:find('moved since build 0', 1, true) ~= nil,
        'and nothing has moved yet', verdict)

    -- ═══ 9. THE STREAM ROUND TRIP, WHICH IS THE OTHER FAULT ═══
    --
    -- "After seeing the shop once in warmup, and going outside its focus area,
    -- then coming back, all the vehicles are floating off the ground again at
    -- waist level." Nobody has ever had a before-reading to compare that
    -- against. Lift a frozen car by 0.90 behind the client's back -- which is
    -- what the report describes -- and the drift column is what catches it.
    --
    -- ONE UP AND ONE DOWN, because the drift has to be read two-sided. The 0.5
    -- drop that is in the tree today is one-sided by construction and that is
    -- half of why it produced "some through the ground but some are still
    -- floating"; a drift check that only noticed cars rising would carry the
    -- same defect into the instrument meant to diagnose it.
    ents[byId.near].z = ents[byId.near].z + 0.90
    ents[byId.mid].z  = ents[byId.mid].z  - 0.40
    run()
    local near2 = cols('near')
    local mid2a = cols('mid')
    ok(mid2a and mid2a.dblt == '-0.40',
        'a car that SANK reports its drift too, with the sign on it',
        mid2a and mid2a.dblt)
    ok(near2 and near2.built == '30.25',
        'the build height is a ledger and does not follow the car',
        near2 and near2.built)
    ok(near2 and near2.now == '31.15' and near2.dblt == '0.90',
        'so a car that moved after it was placed reports the exact drift',
        near2 and (near2.now .. ' / ' .. near2.dblt))
    local verdict2 = lineWith('settled at build')
    ok(verdict2 ~= nil and verdict2:find('moved since build 2', 1, true) ~= nil,
        'and the summary counts both of them, in both directions', verdict2)
    ok(#writes == 0,
        'and the command still puts nothing back -- this round measures only',
        table.concat(writes, ', '))

    -- ═══ 10. A ROW WHOSE CAR IS GONE ═══
    --
    -- The engine deletes local entities on its own (citizenfx/fivem#2623 is
    -- this project's own scar) and a diagnostic that throws on the case it was
    -- opened to investigate is worthless.
    ents[byId.mid] = nil
    ok(run(), '/brshop does not throw when a row has lost its car')
    local mid2 = cols('mid')
    ok(mid2 and mid2.now == '-' and mid2.dblt == '-',
        'and prints a dash where there is nothing to read, not a zero',
        mid2 and (mid2.now .. ' / ' .. mid2.dblt))
    ok(mid2 and mid2.gz == '29.60',
        'while the ground probe still answers, because it is fired at his '
            .. 'coordinate and not at the car', mid2 and mid2.gz)

    -- ═══ 11. THE PAD COMES DOWN AND THE LEDGER GOES WITH IT ═══
    --
    -- A build reading left standing over a pad that has been taken down is a
    -- reading of a PREVIOUS MATCH, and this command would print it as if it
    -- were this one -- which on the `playing` -> `warmup` round trip is the
    -- single most misleading thing it could do, because that round trip is the
    -- bug. So every column that describes a car has to become a dash.
    --
    -- AND A DASH IS NOT AN 'N'. "The world was not resident when this car was
    -- built" and "there is no record of this car being built" are opposite
    -- claims; collapsing them would make a torn-down pad read as thirteen cars
    -- built into an empty world, which is a diagnosis of the very fault
    -- somebody would be running this command to look for.
    BR.State.match.state = BR.MatchState.PLAYING
    quiet(loops['shop.scene'])
    ok(run(), '/brshop does not throw once the pad has been taken down')
    local gone = cols('near')
    ok(gone ~= nil and gone.now == '-' and gone.built == '-',
        'a row whose pad is down prints no heights at all',
        gone and (gone.built .. ' / ' .. gone.now))
    ok(gone ~= nil and gone.bcoll == '-' and gone.bwait == '-'
           and gone.bms == '-',
        'and no build reading either -- a dash, never an N, because "not '
            .. 'recorded" and "the answer was no" are opposite claims',
        gone and (gone.bcoll .. '/' .. gone.bwait .. '/' .. gone.bms))
    local verdict3 = lineWith('settled at build')
    ok(verdict3 ~= nil and verdict3:find('settled at build 0/3', 1, true) ~= nil,
        'and the verdict counts nothing, rather than last match\'s cars',
        verdict3)

    -- ═══ 12. THE DROP IS UNTOUCHED BY ALL OF THIS ═══
    ok(shipped.groundDropM == 0.5,
        'and nothing here has changed where a car goes -- the drop is still '
            .. 'the number he named', tostring(shipped.groundDropM))
end
print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
