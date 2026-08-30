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

    -- ═══ THE OTHER KNOB, WHICH IS PROBABLY THE LIVE ONE ═══
    --
    -- CREATE_OBJECT takes an OBJECT archetype and a car is a VEHICLE archetype,
    -- so the engine may well refuse to build any of these as props -- in which
    -- case `propScale` above is inert and marker 34 is what a player sees. That
    -- marker's size was a hard-coded 0.5 in client/loot.lua and is now carried
    -- on the item beside the marker id, so the two travel together and the
    -- fallback is tunable in one line once the console says which path is live.
    ok(reg ~= nil and reg.fallbackMarker == 34
           and tonumber(reg.fallbackMarkerScale) == 0.375,
        'the fallback marker carries its own size, in metres, beside its id',
        reg and tostring(reg.fallbackMarkerScale) or 'unregistered')

    -- ═══ AND THE TWO MOVE TOGETHER UNTIL SOMEBODY READS A CONSOLE ═══
    --
    -- He resized ONE thing he can see. Nothing here knows which of these two
    -- numbers draws it, so his 75% went on both -- and they must stay equal, or
    -- the day the question is answered the pickup changes size again on its own.
    -- This is not a claim that they are the same knob (they are not: one is a
    -- multiple of the model, the other is metres) -- it is a claim that they are
    -- currently carrying one instruction between them.
    ok(BR.Config.Shop.tokenScale == BR.Config.Shop.tokenMarkerScale,
        'both knobs carry the same 75%, because which one is live is still an '
            .. 'open question',
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
    boughtToast = BR.Config.Shop.boughtToast,
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
    for _, s in ipairs({ BR.PlayerState.ALIVE, BR.PlayerState.LOBBY,
                         BR.PlayerState.SPECTATING, BR.PlayerState.DEAD }) do
        local can, why = BR.ShopSolve.canBuy(st({ playerState = s }))
        ok(can == false and why == BR.ShopSolve.Refusal.STATE,
            ('and shut to a player who is %s during one'):format(s))
    end

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
            done(true, nil)
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
           and buysOf(10)[1].matchId == 1,
        'and the purchase is recorded against this match')

    -- ═══ THE OWNER'S SENTENCE, VERBATIM ═══
    ok(#notices == 1 and notices[1].text ==
        'Thanks for your purchase. It will be available in your inventory '
        .. 'once the match starts.',
        'the toast is the owner\'s wording, exactly',
        notices[1] and notices[1].text)

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
    -- HE WAS NEVER SHORT OF A CAR. He was refused a SECOND one, which is the
    -- rule. So the ceiling counts what a player is HOLDING rather than what a
    -- match sold him, and this block is the previous one inverted.
    reset()
    -- Enough for both cars, so a refusal below can only be the CEILING and
    -- never the money. A player who cannot afford the second would pass these
    -- assertions for a reason that has nothing to do with the rule.
    player(40, { balance = 5000 })
    buy(40, 'runner')
    ok(#buysOf(40) == 1 and buysOf(40)[1].matchId == 1,
        'a purchase starts out bound to the match that sold it')

    BR.Shop.release(40)
    ok(#buysOf(40) == 1 and buysOf(40)[1].matchId == nil,
        'walking out unbinds it -- the car is still owed, it is just no longer '
            .. 'this match\'s business')

    -- ...AND BACK IN, WHICH IS THE CASE THAT PRODUCED TWO CARS.
    buy(40, 'hauler')
    ok(#charged == 1,
        'coming back while a car is still owed buys NOTHING -- one car at '
            .. 'wheels-up, ever, and the second sale is declined rather than '
            .. 'taken and then argued about', #charged)
    ok(#buysOf(40) == 1 and buysOf(40)[1].row == 'runner',
        'so he is still holding exactly the one he paid for', #buysOf(40))

    -- ═══ NOTHING IS FORFEITED AND NOTHING IS REFUNDED ═══
    --
    -- Which is the whole of the answer to "does the older purchase get
    -- forfeited or refunded": neither, because there is never a second one.
    -- "Purchases cannot be refunded" is the owner's standing rule, and the way
    -- to honour it alongside "one car at wheels-up" is not to sell the second.
    ok(#notices == 1,
        'and the refused second press produces no toast of its own -- the '
            .. 'purchase toast is still the only thing this feature says',
        #notices)

    BR.Shop.deliver(matches[1])
    ok(inv[40] ~= nil and #inv[40] == 1 and inv[40][1].item == 'car_runner',
        'the one he owns arrives at wheels-up, alone',
        inv[40] and #inv[40] or 0)
    ok(#buysOf(40) == 0,
        'and a delivered record is dropped rather than lingering to refuse the '
            .. 'next match')

    -- ═══ AND HE CAN BUY AGAIN THE MOMENT HE IS NOT HOLDING ONE ═══
    --
    -- The ceiling must not become a lifetime ban, which is the failure mode on
    -- the other side of it. Once the car has been handed over and the match it
    -- was bought in is behind him, the next warmup sells him another.
    reset()
    player(44, { balance = 5000 })
    buy(44, 'runner')
    BR.Shop.deliver(matches[1])
    BR.Shop.release(44)                      -- he leaves; the record is gone
    buy(44, 'hauler')
    ok(#charged == 2 and #buysOf(44) == 1 and buysOf(44)[1].row == 'hauler',
        'a player who has received his car and moved on buys another next '
            .. 'warmup -- the ceiling is one AT A TIME, not one forever',
        #charged)

    -- ═══ A SURPLUS WAITS RATHER THAN BEING DESTROYED ═══
    --
    -- Unreachable through the handler now, so it is built by hand: two owed
    -- entries on one roster entry, which is the state the previous fix could
    -- produce. Wheels-up hands over ONE. The other is not deleted -- a
    -- paid-for car destroyed is the forfeit the owner never asked for -- it
    -- stays owed and the next wheels-up delivers it.
    reset()
    player(45)
    roster[45].shopBuys = {
        { matchId = nil, row = 'runner', paid = 750, delivered = false },
        { matchId = nil, row = 'hauler', paid = 400, delivered = false },
    }
    BR.Shop.deliver(matches[1])
    ok(inv[45] ~= nil and #inv[45] == 1 and inv[45][1].item == 'car_runner',
        'two owed cars produce ONE car at this wheels-up, the older of them',
        inv[45] and #inv[45] or 0)
    ok(#buysOf(45) == 1 and buysOf(45)[1].row == 'hauler',
        'and the other is still owed -- not forfeited, not refunded, waiting',
        #buysOf(45))
    ok(#dropped == 0,
        'and nothing was quietly dropped on the floor to make the count work')

    BR.Shop.deliver(matches[1])
    ok(inv[45] ~= nil and #inv[45] == 2,
        'the next wheels-up hands over the one that waited',
        inv[45] and #inv[45] or 0)
    ok(#buysOf(45) == 0, 'and then there is nothing left owed')

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

    -- THE NUMBER IS THE OWNER'S, PASSED THROUGH. Nothing in this tree claims to
    -- know what marker 34 draws.
    ok(BR.Config.Shop.tokenMarker == 34,
        'and the number is 34, which is the one he named')
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
    local freeze = cli:find('FreezeEntityPosition', 1, true)
    ok(ground ~= nil and freeze ~= nil and ground < freeze,
        'and it runs BEFORE the freeze -- after it, the native is a no-op that '
            .. 'still returns true',
        ('ground@%s freeze@%s'):format(tostring(ground), tostring(freeze)))

    -- IT RETURNS A BOOL, SO IT GOES THROUGH isTrue. Ten shipped instances of
    -- reading a native's 0 as truth on this project; this one would invert the
    -- fallback and leave a failed grounding unreported.
    ok(cli:find('isTrue(landed)', 1, true) ~= nil,
        'the grounding result is read through isTrue, because 0 is truthy')

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
describe('the plate is a yard sign: stationary, welded to the car, in metres')
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
-- So client/dui.lua is LOADED here, with a GetOffsetFromEntityInWorldCoords that
-- performs a real GTA heading rotation, and the four corners it produces are
-- read back out of the DrawSpritePoly calls. Every assertion below fails against
-- the old drawWorld path -- there are no polys at all to read.
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

    -- --- one car, at a known place, facing a known way --------------------
    --
    -- GTA HEADING IS COUNTER-CLOCKWISE DEGREES FROM NORTH, so forward is
    -- (-sin h, cos h) and right is (cos h, sin h). Written out rather than
    -- taken from the code under test: a stub that shared the implementation's
    -- convention would agree with it however wrong both were.
    local CAR = { x = 100.0, y = 200.0, z = 30.0, h = 0.0 }
    local VEH = 4242

    function DoesEntityExist(e) return e == VEH end
    function GetOffsetFromEntityInWorldCoords(e, lx, ly, lz)
        local r = math.rad(CAR.h)
        local cs, sn = math.cos(r), math.sin(r)
        return {
            x = CAR.x + lx * cs - ly * sn,
            y = CAR.y + lx * sn + ly * cs,
            z = CAR.z + lz,
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

    -- ═══ 4. IT IS WELDED TO THE CAR'S OWN AXES ═══
    --
    -- Turn the car and the sign turns with it, because its corners are entity
    -- offsets. At heading 0 the sign stands across the world's X axis, in front
    -- of the car's nose; at heading 90 the same sign stands across Y.
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

    -- ═══ 7. THE CONFIG KNOB IS A LENGTH, AND THE SCREEN FRACTION IS GONE ═══
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

    -- ═══ 8. THE TITLE, AND THE CURRENCY WORD'S CASE ═══
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

    -- ═══ 9. THE ORANGE IS THE MARKET PAGE'S OWN TOKEN, END TO END ═══
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

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
