-- Unit tests for the in-match Ammu-Nation gun shop (#274).
--
-- ═══ WHAT THIS SUITE IS ACTUALLY FOR ═══
--
-- One rule funds this whole feature and it is not a thing a playtest can check:
--
--   "we're not planning to (as of now) sell items which could not otherwise be
--    found in the wild - just a convenience with a fee" (owner, 2026-09-08)
--
-- A shop that breaks that rule looks EXACTLY like a shop that keeps it. Nobody
-- standing at a counter can see that the gun they just bought is one the map
-- would never have given them; they can only see a gun. The failure is silent,
-- it is permanent, and by the time somebody notices, the reason it happened --
-- a rarity moved three commits ago -- is unrecoverable.
--
-- So the assertions below are about the DERIVATION rather than about a list.
-- The catalogue is not compared against a copy of itself; it is compared
-- against BR.Config.Weapons, BR.Config.AirdropWeapons, BR.Config.Melee,
-- BR.Config.Throwables and BR.Config.AmmoOrder -- the shipped tables the rest of
-- the game rolls loot out of -- from BOTH directions:
--
--   every row in the shop is in the world's own weapon table at RARE or above,
--   and every weapon in that table at RARE or above is in the shop.
--
-- Those two together are the rule. Either one alone is half of it.
--
-- ═══ TWO PLACES WHERE A COPY IS DELIBERATE, AND THEY ARE THE OPPOSITE CASE ═══
--
-- The eleven store anchors and the rarity COUNTS are retyped in this file on
-- purpose. That is DOUBLE ENTRY, the technique tools/test_shop.lua uses for the
-- owner's showroom survey: the numbers here were typed from the source note and
-- config/gunshop.lua was written from it independently, so a transposed digit in
-- either one makes the two disagree and fails a test. Reading them out of the
-- config would assert nothing at all.
--
-- The counts are a TRIPWIRE rather than a rule. 11 rare, 10 epic, 4 legendary is
-- what config/weapons.lua holds today; the day the owner moves a rarity that
-- number changes and this suite says so. Fixing it is editing one integer here
-- AFTER checking that the gun which moved has a price -- which is the whole
-- point of being told.
--
-- ═══ WHAT THIS CANNOT TELL YOU ═══
--
-- There is no FiveM here. Whether the eleven anchors are inside their buildings,
-- whether a ground probe finds the shop floor at any of them, whether either
-- clerk model streams, and whether 2.5m is the right reach are questions only a
-- playtest answers. The z values in particular are asserted to be PRESENT and
-- to be the surveyed numbers, and this file makes no claim whatever about what
-- is at that height -- see the long block in config/gunshop.lua about why no
-- clerk z is authored at all.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_gunshop.lua

local ROOT = 'resources/[fivem-royale]/'

local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/geo.lua',      -- BR.Dist and BR.NormHash
    -- THE SHIPPED WEAPON AND LOOT TABLES, NOT FIXTURES. These two files are the
    -- SUBJECT of half this suite: the catalogue is derived from them, so a
    -- fixture here would be a test that the derivation agrees with itself.
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/gunshop.lua',
    'br_lib/shared/gunshop_solve.lua',
})

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

local G = BR.Config.Gunshop
local S = BR.GunshopSolve

-- ---------------------------------------------------------------------------
describe('the rule the whole feature rests on is written down')
-- ---------------------------------------------------------------------------
--
-- ═══ THE HEADER IS THE ENFORCEMENT, SO THE HEADER IS UNDER TEST ═══
--
-- Nothing in code can check that a catalogue row names something findable on the
-- map (see the config's own header for why). What stops this shop becoming
-- pay-to-win is that the next person to edit the price table READS THE RULE
-- FIRST -- so the rule going missing in a tidy-up is a real regression with a
-- real cost, and it is the one regression a comment test can catch.
do
    local src = readFile(ROOT .. 'br_lib/config/gunshop.lua')

    ok(src:find('sell items which could not otherwise be found in the wild', 1, true) ~= nil,
        "the owner's ruling of 2026-09-08 is quoted verbatim in the header")

    ok(src:find('in%-match wallet should not exist, agreed%. the player has one Volts bank%.') ~= nil,
        'and so is the one-bank ruling that goes with it')

    ok(src:find('NOTHING IS SOLD HERE THAT CANNOT BE FOUND IN THE WILD.', 1, true) ~= nil,
        'and the rule those two produce is stated as a rule, not left to be '
            .. 'inferred from them')

    ok(src:find('convenience with a fee', 1, true) ~= nil,
        'including his own words for what the shop is')
end

-- ---------------------------------------------------------------------------
describe('the catalogue is DERIVED, and that is checked from both directions')
-- ---------------------------------------------------------------------------

local rows, rejects = G.build()

do
    ok(#rejects == 0,
        'nothing the shipped config offers is dropped at load',
        #rejects > 0 and (rejects[1].id .. ': ' .. rejects[1].why) or nil)

    -- ═══ DIRECTION 1: EVERYTHING ON SALE IS IN THE WORLD'S OWN TABLE ═══
    local byId = {}
    for _, w in ipairs(BR.Config.Weapons) do byId[w.id] = w end

    local strays = {}
    for _, r in ipairs(rows) do
        if r.kind == BR.ItemKind.WEAPON then
            local w = byId[r.id]
            if not w or w.rarity < BR.Rarity.RARE then
                strays[#strays + 1] = r.id
            end
        end
    end
    ok(#strays == 0,
        'every gun on sale is a row of BR.Config.Weapons at RARE or above -- '
            .. 'i.e. a gun the map itself can roll',
        #strays > 0 and table.concat(strays, ', ') or nil)

    -- ═══ DIRECTION 2: EVERYTHING IN THE WORLD'S TABLE AT RARE+ IS ON SALE ═══
    --
    -- THE HALF A HAND-WRITTEN LIST WOULD FAIL. A copied catalogue passes
    -- direction 1 forever -- everything on it was real when it was typed -- and
    -- fails this one silently the moment a rarity moves. This is the assertion
    -- that would have caught it.
    local missing = {}
    for _, w in ipairs(BR.Config.Weapons) do
        if w.rarity >= BR.Rarity.RARE and not S.rowById(rows, w.id) then
            missing[#missing + 1] = w.id
        end
    end
    ok(#missing == 0,
        'and every gun in BR.Config.Weapons at RARE or above is on sale -- so '
            .. 'the shop and the map read one table',
        #missing > 0 and table.concat(missing, ', ') or nil)

    -- ═══ NOTHING BELOW THE FLOOR ═══
    local floor = S.minRarity()
    ok(floor == BR.Rarity.RARE,
        'the floor is RARE, named once by BR.GunshopSolve.minRarity', floor)

    local cheap = {}
    for _, r in ipairs(rows) do
        if r.kind == BR.ItemKind.WEAPON and r.rarity < floor then
            cheap[#cheap + 1] = r.id
        end
    end
    ok(#cheap == 0, 'and nothing below it is stocked',
        #cheap > 0 and table.concat(cheap, ', ') or nil)
end

-- ---------------------------------------------------------------------------
describe('what is deliberately NOT sold')
-- ---------------------------------------------------------------------------
do
    -- ═══ THE AIRDROP SHELF, WHICH IS THE ONE THAT WOULD BREAK THE RULE ═══
    --
    -- Owner, 2026-08-21: RPG, grenade launcher, railgun and minigun are ultra
    -- rare AIRDROP loot. They are in no rarity bucket, so no world roll produces
    -- them -- which makes them the exact category the 2026-09-08 ruling
    -- forbids: things that could not otherwise be found in the wild.
    --
    -- CHECKED AGAINST THE REAL TABLE rather than against four names typed here,
    -- so a fifth airdrop weapon is covered on the day it is added.
    local sold = {}
    for _, w in ipairs(BR.Config.AirdropWeapons) do
        if S.rowById(rows, w.id) then sold[#sold + 1] = w.id end
    end
    ok(#sold == 0,
        'not one BR.Config.AirdropWeapons row is on sale -- selling one would '
            .. 'be selling the one thing the map cannot give you',
        #sold > 0 and table.concat(sold, ', ') or nil)

    -- ═══ MELEE, EXCLUDED FOR FREE AND DELIBERATELY ═══
    --
    -- BR.Config.Melee is a SEPARATE table from BR.Config.Weapons, so deriving
    -- from Weapons drops the whole list without a line of filtering. This
    -- asserts the outcome is what was wanted rather than merely what happened.
    local blades = {}
    for _, m in ipairs(BR.Config.Melee) do
        if S.rowById(rows, m.id) then blades[#blades + 1] = m.id end
    end
    ok(#blades == 0,
        'no melee weapon is on sale -- a separate table, and its exclusion is '
            .. 'intended rather than accidental',
        #blades > 0 and table.concat(blades, ', ') or nil)

    local thrown = {}
    for _, t in ipairs(BR.Config.Throwables) do
        if S.rowById(rows, t.id) then thrown[#thrown + 1] = t.id end
    end
    ok(#thrown == 0,
        'and no throwable either -- also a separate table, and the owner has '
            .. 'not ruled on them either way',
        #thrown > 0 and table.concat(thrown, ', ') or nil)

    ok(S.rowById(rows, 'fists') == nil and S.rowById(rows, BR.Config.Fists.id) == nil,
        'and fists are not for sale, which would be funny once')
end

-- ---------------------------------------------------------------------------
describe('the shape of the catalogue as it stands today')
-- ---------------------------------------------------------------------------
--
-- ═══ A TRIPWIRE, NOT A RULE. READ THE NOTE AT THE TOP OF THIS FILE ═══
--
-- These three integers are what config/weapons.lua holds on 2026-09-08. They
-- are pinned so that a rarity change is ANNOUNCED rather than absorbed: the gun
-- that moved needs a price in the new band, and the band it left is now one
-- shorter. If this fails, check the price table first, then edit the number.
do
    local n = { [BR.Rarity.RARE] = 0, [BR.Rarity.EPIC] = 0, [BR.Rarity.LEGENDARY] = 0 }
    for _, r in ipairs(rows) do
        if r.kind == BR.ItemKind.WEAPON then n[r.rarity] = (n[r.rarity] or 0) + 1 end
    end

    ok(n[BR.Rarity.RARE] == 11, 'eleven rare guns', n[BR.Rarity.RARE])
    ok(n[BR.Rarity.EPIC] == 10, 'ten epic guns', n[BR.Rarity.EPIC])
    ok(n[BR.Rarity.LEGENDARY] == 4, 'four legendary guns', n[BR.Rarity.LEGENDARY])

    local ammo = S.ofKind(rows, BR.ItemKind.AMMO)
    ok(#ammo == #BR.Config.AmmoOrder and #ammo == 5,
        'and all five ammo pools -- BR.Config.AmmoOrder, in its order', #ammo)

    ok(#rows == 25 + 5, 'thirty rows in total', #rows)

    -- ORDER IS THE SOURCE TABLES', so anything that renders this list gets a
    -- stable order without sorting it. Asserted by walking BR.Config.Weapons and
    -- checking the catalogue's guns appear in the same relative order.
    local want, i = {}, 0
    for _, w in ipairs(BR.Config.Weapons) do
        if w.rarity >= BR.Rarity.RARE then want[#want + 1] = w.id end
    end
    local sameOrder = true
    for _, r in ipairs(rows) do
        if r.kind == BR.ItemKind.WEAPON then
            i = i + 1
            if want[i] ~= r.id then sameOrder = false end
        end
    end
    ok(sameOrder,
        'the guns are in BR.Config.Weapons order, not pairs() order')
end

-- ---------------------------------------------------------------------------
describe("the prices sit inside the owner's bands, 2026-09-08")
-- ---------------------------------------------------------------------------
--
-- "prices should be a range per weapon class - rare is 100-150 Volts, epic is
--  200-275 Volts, and legendary is 400-500 Volts."
--
-- HIS NUMBERS, RETYPED FROM HIS MESSAGE. Double entry again: config/gunshop.lua
-- was priced from the same sentence independently.
local BANDS = {
    [BR.Rarity.RARE]      = { 100, 150 },
    [BR.Rarity.EPIC]      = { 200, 275 },
    [BR.Rarity.LEGENDARY] = { 400, 500 },
}

do
    local lo, hi = {}, {}
    local outside = {}

    for _, r in ipairs(rows) do
        if r.kind == BR.ItemKind.WEAPON then
            local b = BANDS[r.rarity]
            if not b or r.price < b[1] or r.price > b[2] then
                outside[#outside + 1] = ('%s %d'):format(r.id, r.price)
            end
            if not lo[r.rarity] or r.price < lo[r.rarity] then lo[r.rarity] = r.price end
            if not hi[r.rarity] or r.price > hi[r.rarity] then hi[r.rarity] = r.price end
        end
    end

    ok(#outside == 0, 'every gun is priced inside the band for its rarity',
        #outside > 0 and table.concat(outside, ', ') or nil)

    -- ═══ AND THE BANDS ARE SPREAD, NOT CLUSTERED ═══
    --
    -- "a RANGE per weapon class." Eleven guns all at 100 would satisfy the
    -- assertion above and would not be what he asked for, so both ENDS of each
    -- band have to be occupied.
    for rarity, b in pairs(BANDS) do
        ok(lo[rarity] == b[1] and hi[rarity] == b[2],
            ('the %s band uses both its ends (%d and %d)')
                :format(BR.RarityInfo[rarity].key, b[1], b[2]),
            ('%s..%s'):format(tostring(lo[rarity]), tostring(hi[rarity])))
    end

    -- ═══ THE ORDERING AXIS IS PER-SHOT `damage`, ASCENDING ═══
    --
    -- config/gunshop.lua says so and this is what holds it to it. Sorting a band
    -- by price must produce damage in non-decreasing order -- which is the claim
    -- the config makes, tested rather than asserted in prose.
    local byId = {}
    for _, w in ipairs(BR.Config.Weapons) do byId[w.id] = w end

    for rarity in pairs(BANDS) do
        local band = {}
        for _, r in ipairs(rows) do
            if r.kind == BR.ItemKind.WEAPON and r.rarity == rarity then
                band[#band + 1] = r
            end
        end
        table.sort(band, function(a, b) return a.price < b.price end)

        local monotone, where = true, nil
        for k = 2, #band do
            local a, b = byId[band[k - 1].id], byId[band[k].id]
            if a.damage > b.damage then
                monotone = false
                where = ('%s(%d) at %d then %s(%d) at %d')
                    :format(a.id, a.damage, band[k - 1].price,
                            b.id, b.damage, band[k].price)
            end
        end
        ok(monotone,
            ('the %s band is ordered by damage, cheapest weakest')
                :format(BR.RarityInfo[rarity].key), where)
    end

    -- ═══ NO DEAD PRICES ═══
    --
    -- The other direction of the same drift: a price for a gun that is not sold
    -- is a number the owner tuned that changes nothing, and it is what is left
    -- behind when a weapon is deleted or demoted.
    local dead = {}
    for id in pairs(G.prices) do
        if not S.rowById(rows, id) then dead[#dead + 1] = id end
    end
    ok(#dead == 0,
        'and no price is authored for something the shop does not sell',
        #dead > 0 and table.concat(dead, ', ') or nil)

    local n = 0
    for _ in pairs(G.prices) do n = n + 1 end
    ok(n == 25, 'twenty-five prices for twenty-five guns', n)
end

-- ---------------------------------------------------------------------------
describe('ammo: cheap, all five pools, and one ground pickup per purchase')
-- ---------------------------------------------------------------------------
--
-- "ammo should be cheap (20-50 Volts)"
do
    local ammo = S.ofKind(rows, BR.ItemKind.AMMO)

    local bad = {}
    for _, r in ipairs(ammo) do
        if r.price < 20 or r.price > 50 then
            bad[#bad + 1] = ('%s %d'):format(r.id, r.price)
        end
    end
    ok(#bad == 0, 'every pool is priced in his 20-50 band',
        #bad > 0 and table.concat(bad, ', ') or nil)

    local lo, hi = 1e9, -1e9
    for _, r in ipairs(ammo) do
        if r.price < lo then lo = r.price end
        if r.price > hi then hi = r.price end
    end
    ok(lo == 20 and hi == 50, 'and both ends of it are used',
        ('%d..%d'):format(lo, hi))

    -- ═══ THE PRICE ORDER IS SCARCITY, AND BOTH SCARCITY NUMBERS AGREE ═══
    --
    -- config/gunshop.lua prices the pools by how freely the world gives them
    -- out, and claims the two independent measures of that -- the ground pickup
    -- size and the inventory cap -- put the five pools in the same order. That
    -- claim is checked here rather than trusted, because it is the only reason
    -- the price order is defensible at all.
    local sorted = {}
    for _, r in ipairs(ammo) do sorted[#sorted + 1] = r end
    table.sort(sorted, function(a, b) return a.price < b.price end)

    local pickOk, capOk = true, true
    for k = 2, #sorted do
        local a, b = sorted[k - 1].pool, sorted[k].pool
        if BR.Config.AmmoPickups[a].amount < BR.Config.AmmoPickups[b].amount then
            pickOk = false
        end
        if BR.Config.AmmoCaps[a] < BR.Config.AmmoCaps[b] then capOk = false end
    end
    ok(pickOk,
        'cheapest pool has the biggest ground pickup, dearest the smallest')
    ok(capOk,
        'and the inventory caps put the five in the same order, which is what '
            .. 'makes the axis more than one number chosen to fit')

    -- ═══ THE BUNDLE IS ONE GROUND PICKUP, DERIVED ═══
    --
    -- config/gunshop.lua authors NO bundle sizes -- it authors the rule, and the
    -- solver reads BR.Config.AmmoPickups. So this compares the catalogue against
    -- the loot table rather than against five numbers typed into the config,
    -- which is the same argument the weapon derivation makes.
    --
    -- WHEN THE OWNER PINS A POOL this test must be updated with him: an
    -- authored `bundle` is his answer and it is allowed to differ from the loot
    -- amount. Today none is authored, so the whole set must derive.
    local pinned, wrong = {}, {}
    for _, r in ipairs(ammo) do
        local authored = G.ammo[r.pool] and G.ammo[r.pool].bundle
        if authored ~= nil then
            pinned[#pinned + 1] = r.pool
        elseif r.stack.count ~= BR.Config.AmmoPickups[r.pool].amount then
            wrong[#wrong + 1] = ('%s %d vs %d'):format(
                r.pool, r.stack.count, BR.Config.AmmoPickups[r.pool].amount)
        end
    end
    ok(#pinned == 0,
        'no pool has an authored bundle size yet -- the owner has not answered',
        #pinned > 0 and table.concat(pinned, ', ') or nil)
    ok(#wrong == 0,
        'so a purchase is exactly one ground pickup, read out of '
            .. 'BR.Config.AmmoPickups and not copied into the shop config',
        #wrong > 0 and table.concat(wrong, ', ') or nil)

    -- HIS OVERRIDE STILL WORKS, tested on a fixture so the shipped config stays
    -- underived. This is the line his answer lands on.
    local fixture = {
        prices = {},
        ammo   = { light = { price = 30, bundle = 90 } },
    }
    ok(S.ammoBundle(fixture, 'light', BR.Config.AmmoPickups) == 90,
        'and an authored bundle wins over the derivation')
    ok(S.ammoBundle(fixture, 'smg', BR.Config.AmmoPickups) == 60,
        'while the pools he did not pin keep deriving')
end

-- ---------------------------------------------------------------------------
describe('every row pays out the loot system\'s own stack')
-- ---------------------------------------------------------------------------
--
-- ═══ "A CONVENIENCE WITH A FEE", MADE LITERAL ═══
--
-- `row.stack` is `{ item, kind, rarity, count }` -- what BR.RollLootStack hands
-- back for the same gun or the same pool. So a purchase reaches the inventory
-- through the code path a pickup already uses, and there is no second shape for
-- the two to disagree about.
do
    local byId = {}
    for _, w in ipairs(BR.Config.Weapons) do byId[w.id] = w end

    local bad = {}
    for _, r in ipairs(rows) do
        local st = r.stack
        if type(st) ~= 'table' then
            bad[#bad + 1] = r.id .. ': no stack'
        elseif r.kind == BR.ItemKind.WEAPON then
            local w = byId[r.id]
            if st.item ~= r.id or st.kind ~= BR.ItemKind.WEAPON
               or st.rarity ~= w.rarity or st.count ~= 1 then
                bad[#bad + 1] = r.id .. ': wrong weapon stack'
            end
        else
            -- AMMO IS KEYED BY THE BARE POOL NAME, not by the catalogue id. The
            -- inventory has always done it that way (BR.RollLootStack,
            -- BR.WarmupCrateItem) and the shop is not allowed to change it.
            if st.item ~= r.pool or st.kind ~= BR.ItemKind.AMMO
               or st.rarity ~= BR.Rarity.COMMON or (st.count or 0) <= 0 then
                bad[#bad + 1] = r.id .. ': wrong ammo stack'
            end
        end
    end
    ok(#bad == 0, 'every stack is the shape the ground already drops',
        #bad > 0 and table.concat(bad, ', ') or nil)

    -- NO NEW ITEM IDS ARE MINTED FOR WEAPONS, which is the contrast with the
    -- warmup showroom's `car_<id>`. A carbine is already an inventory item.
    local minted = {}
    for _, r in ipairs(rows) do
        if r.kind == BR.ItemKind.WEAPON and not BR.Config.WeaponById[r.stack.item] then
            minted[#minted + 1] = r.id
        end
    end
    ok(#minted == 0,
        'and every gun sold is already a BR.Config.WeaponById item -- no second '
            .. 'name is invented for a thing that has one',
        #minted > 0 and table.concat(minted, ', ') or nil)

    -- THE AMMO CATALOGUE ID IS PREFIXED AND CARRIES NO COLON. Item ids reach
    -- br_ui as artwork filenames; see BR.GunshopSolve.ammoIdFor.
    local colons = {}
    for _, r in ipairs(rows) do
        if r.id:find(':', 1, true) then colons[#colons + 1] = r.id end
    end
    ok(#colons == 0, 'and no catalogue id contains a colon',
        #colons > 0 and table.concat(colons, ', ') or nil)

    ok(S.ammoIdFor('light') == 'ammo_light', 'ammo ids are prefixed')
    ok(S.ammoIdFor(nil) == nil and S.ammoIdFor('') == nil,
        'and nothing is minted from nothing')
end

-- ---------------------------------------------------------------------------
describe('the eleven counters, against the survey')
-- ---------------------------------------------------------------------------
--
--- ═══ RETYPED FROM THE SOURCE NOTE, NOT FROM THE CONFIG ═══
---
--- DOUBLE ENTRY. config/gunshop.lua was written from the same note
--- independently, so a transposed digit in either makes the two disagree.
---
---   id, x, y, z, heading, range?, clerk
local SURVEY = {
    { 'pillbox',     23.6862, -1106.4610,  29.9159, 160.0000, true },
    { 'sandy',     1693.5720,  3761.6010,  34.8242, 227.3919, false, 'country' },
    { 'hawick',     252.8583,   -51.6284,  70.0600,  69.9999 },
    { 'lamesa',     841.0564, -1034.7620,  28.3137,   0.0000 },
    { 'paleto',    -330.2908,  6085.5480,  31.5737, 224.9999, false, 'country' },
    { 'seoul',     -660.9294,  -934.1031,  21.9481, 180.0000 },
    { 'morning',  -1304.9760,  -395.8181,  36.8147,  75.7783 },
    { 'route68',  -1117.6120,  2700.2640,  18.6730, 221.8271 },
    { 'chumash',  -3172.5110,  1089.4120,  20.9576, 246.5813 },
    { 'palomino',  2566.5920,   293.1332, 108.8538,   0.0000 },
    { 'cypress',    808.8609, -2158.5080,  29.7379,   0.0000, true },
}

local stores, storeRejects = S.stores(G)

do
    ok(#storeRejects == 0, 'no counter is dropped at load',
        #storeRejects > 0 and (storeRejects[1].id .. ': ' .. storeRejects[1].why) or nil)
    ok(#stores == #SURVEY and #stores == 11, 'eleven counters survive', #stores)
    ok(S.enabled(G) == true, 'so the gun shops exist')

    local byId = {}
    for _, s in ipairs(stores) do byId[s.id] = s end

    for _, row in ipairs(SURVEY) do
        local id, x, y, z, h, range, clerk = table.unpack(row)
        local s = byId[id]
        ok(s ~= nil, id .. ' is on the map')
        if s then
            ok(s.x == x and s.y == y and s.z == z,
                id .. ': stands exactly where it was surveyed',
                ('%s,%s,%s'):format(s.x, s.y, s.z))
            ok(s.heading == h, id .. ': the counter faces the surveyed way',
                s.heading)
            ok((s.range == true) == (range == true),
                id .. ': the shooting-range flag is right', tostring(s.range))
            ok(s.clerk == clerk, id .. ': wants the right clerk',
                tostring(s.clerk))
        end
    end
end

-- ---------------------------------------------------------------------------
describe('NO CLERK HEIGHT IS AUTHORED, and nothing may quietly add one')
-- ---------------------------------------------------------------------------
--
-- ═══ THE SOURCES DISAGREE BY UP TO ABOUT 1.1m ON WHAT THE TABULATED z MEANS
--     ═══
--
-- Some tables carry the interior FLOOR at the counter and others carry a
-- standing ped's recorded center, and the number alone does not say which. A
-- metre is the difference between a clerk on the floor, a clerk buried to the
-- waist, and a clerk floating. The client ground-probes; this config carries the
-- anchor and two empty override slots.
--
-- WHY THIS IS A TEST AND NOT A COMMENT. The obvious "fix" when a clerk appears
-- at the wrong height in game is to type a better z into the config, one store
-- at a time, and it works for that store on that build. The warmup showroom paid
-- three playtest rounds for exactly that instinct (`veto`, config/shop.lua). So
-- the key set of a store row is FIXED here: a new height field fails the build
-- and the person adding it reads this paragraph.
do
    local ALLOWED = {
        id = true, x = true, y = true, z = true, heading = true,
        range = true, clerk = true,
        -- The two override slots. Both nil everywhere today; both exist so the
        -- fix for a bad probe is a documented field rather than an invented one.
        zOverride = true, probeFromM = true,
    }

    local extra, authored = {}, {}
    for _, s in ipairs(G.stores) do
        for k in pairs(s) do
            if not ALLOWED[k] then extra[#extra + 1] = s.id .. '.' .. tostring(k) end
        end
        if s.zOverride ~= nil then authored[#authored + 1] = s.id end
    end

    ok(#extra == 0,
        'no store row carries a field outside the fixed set -- in particular '
            .. 'none carries a clerk height under any name',
        #extra > 0 and table.concat(extra, ', ') or nil)

    ok(#authored == 0,
        'and no store overrides its z, so all eleven are ground-probed',
        #authored > 0 and table.concat(authored, ', ') or nil)

    -- THE ANCHOR IS STILL REQUIRED TO BE THERE. "Do not trust the z" is not "do
    -- not carry one": it is where the downward probe starts.
    local noZ = {}
    for _, s in ipairs(G.stores) do
        if type(s.z) ~= 'number' then noZ[#noZ + 1] = s.id end
    end
    ok(#noZ == 0, 'every store still carries the tabulated anchor to probe from',
        #noZ > 0 and table.concat(noZ, ', ') or nil)

    local src = readFile(ROOT .. 'br_lib/config/gunshop.lua')
    ok(src:find('DO NOT\n%-%- AUTHOR ONE') ~= nil
       or src:find('DO NOT AUTHOR ONE', 1, true) ~= nil
       or src:find('SO NOTHING HERE AUTHORS A CLERK z', 1, true) ~= nil,
        'and the decision is recorded in the file itself, where somebody about '
            .. 'to type a height will meet it')
end

-- ---------------------------------------------------------------------------
describe('which clerk stands behind which counter')
-- ---------------------------------------------------------------------------
do
    local country, city = {}, {}
    for _, s in ipairs(stores) do
        local m = S.clerkModel(G, s)
        if m == G.clerkModels.country then country[#country + 1] = s.id
        elseif m == G.clerkModels.city then city[#city + 1] = s.id end
    end
    table.sort(country)

    ok(#country == 2 and country[1] == 'paleto' and country[2] == 'sandy',
        'the two country stores are sandy and paleto',
        table.concat(country, ', '))
    ok(#city == 9, 'and the other nine take the city clerk', #city)

    -- AN UNKNOWN KEY IS A REJECT, NOT A FALLBACK. A typo must not silently put
    -- the city model in a country store and look like the decision.
    local okv, why = S.validateStore({ id = 'x', x = 0.0, y = 0.0, z = 0.0,
                                       heading = 0.0, clerk = 'contry' })
    ok(okv == false and why and why:find('clerk', 1, true) ~= nil,
        'a misspelled clerk key is refused rather than defaulted', why)

    ok(S.clerkModel({}, stores[1]) == nil,
        'and with no model table a caller gets nil rather than an invented '
            .. 'model name')
end

-- ---------------------------------------------------------------------------
describe('standing at a counter')
-- ---------------------------------------------------------------------------
do
    local pillbox = S.rowById and nil
    for _, s in ipairs(stores) do if s.id == 'pillbox' then pillbox = s end end

    local at, d = S.nearest(stores, pillbox.x, pillbox.y, G.reachM)
    ok(at == pillbox and d == 0.0, 'standing on the anchor resolves that store')

    at = S.nearest(stores, pillbox.x + 1.0, pillbox.y, G.reachM)
    ok(at == pillbox, 'and so does standing a metre off it')

    at = S.nearest(stores, pillbox.x + 50.0, pillbox.y, G.reachM)
    ok(at == nil, 'fifty metres away is not at a counter')

    -- 2-D, WHICH IS LOAD-BEARING HERE. The z is the number this feature refuses
    -- to trust, so the reach must not be measured against it -- a player on the
    -- shop floor is at the counter whatever the anchor's height claims.
    at = S.nearest(stores, pillbox.x, pillbox.y, G.reachM)
    ok(at == pillbox,
        'the reach is flat, so an anchor z that is a metre out cannot put a '
            .. 'player outside a counter they are standing at')

    -- THE NEAREST, NOT MERELY ONE IN REACH.
    local fixture = {
        { id = 'a', x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        { id = 'b', x = 3.0, y = 0.0, z = 0.0, heading = 0.0 },
    }
    at = S.nearest(fixture, 2.0, 0.0, 5.0)
    ok(at ~= nil and at.id == 'b', 'two in reach resolves to the nearer')
    at = S.nearest(fixture, 1.0, 0.0, 5.0)
    ok(at ~= nil and at.id == 'a', 'from the other side too')
    at = S.nearest(fixture, 1.5, 0.0, 5.0)
    ok(at ~= nil and at.id == 'a', 'and a tie goes to the earlier row, stably')

    ok(S.nearest(stores, pillbox.x, pillbox.y, nil) == nil
       and S.nearest(stores, pillbox.x, pillbox.y, 0.0) == nil,
        'no reach is no counter, rather than every counter')
    ok(S.nearest(nil, 0.0, 0.0, 5.0) == nil
       and S.nearest(stores, nil, 0.0, 5.0) == nil,
        'and a missing anything answers nil rather than throwing')

    -- THE ELEVEN ARE DISTRICTS APART, so unlike the warmup showroom no press is
    -- ever ambiguous. Asserted rather than assumed, because the reach was chosen
    -- on the strength of it.
    local tooClose = {}
    for i = 1, #stores do
        for j = i + 1, #stores do
            local a, b = stores[i], stores[j]
            if BR.Dist(a.x, a.y, b.x, b.y) < G.reachM * 4.0 then
                tooClose[#tooClose + 1] = a.id .. '/' .. b.id
            end
        end
    end
    ok(#tooClose == 0,
        'no two counters are within four reaches of each other, which is why '
            .. 'a radius alone would have been enough here',
        #tooClose > 0 and table.concat(tooClose, ', ') or nil)
end

-- ---------------------------------------------------------------------------
describe('a gun with no price is DROPPED, and the rest of the shop survives')
-- ---------------------------------------------------------------------------
--
-- The catalogue is derived and the price table is authored, so they can come
-- apart in one direction: a gun arrives at RARE and nobody prices it. A
-- half-priced catalogue must be a HALF-STOCKED SHOP rather than a crash, and the
-- console must say which gun -- the way server/shop.lua's resolve() does.
do
    local R = BR.Rarity
    local weapons = {
        { id = 'cheap',   label = 'Cheap',   rarity = R.COMMON,    damage = 10 },
        { id = 'priced',  label = 'Priced',  rarity = R.RARE,      damage = 20 },
        { id = 'nameless',label = 'Nameless',rarity = R.EPIC,      damage = 30 },
        { id = 'gold',    label = 'Gold',    rarity = R.LEGENDARY, damage = 40 },
    }
    local cfg = {
        prices = { priced = 120, gold = 450 },
        ammo   = {},
    }

    local r, rj = S.catalogue(cfg, { weapons = weapons })

    ok(#r == 2 and r[1].id == 'priced' and r[2].id == 'gold',
        'the priced guns are still on sale', #r)
    ok(#rj == 1 and rj[1].id == 'nameless' and rj[1].why == 'no price',
        'the unpriced one is dropped, by name and with a reason',
        #rj > 0 and (rj[1].id .. ': ' .. rj[1].why) or '(nothing rejected)')
    ok(S.rowById(r, 'cheap') == nil,
        'and the common gun is simply below the floor -- not a reject, because '
            .. 'nobody was expected to price it')

    -- A ZERO IS NOT A PRICE, and neither is a fraction. Volts are whole numbers.
    local zeroed = { prices = { priced = 0 }, ammo = {} }
    local r2, rj2 = S.catalogue(zeroed, { weapons = weapons })
    ok(#r2 == 0 and #rj2 == 3,
        'a zero price drops the row rather than giving the gun away', #r2)
    local frac = { prices = { priced = 99.5 }, ammo = {} }
    local r3 = S.catalogue(frac, { weapons = weapons })
    ok(#r3 == 0, 'and so does half a Volt')
end

-- ---------------------------------------------------------------------------
describe('the airdrop shelf cannot reach the counter even by a caller mistake')
-- ---------------------------------------------------------------------------
--
-- Deriving from BR.Config.Weapons already excludes the shelf. This is the second
-- lock: the one edit that would defeat the first is somebody passing the MERGED
-- BR.Config.WeaponById in as the source, which contains every airdrop weapon at
-- LEGENDARY with a price band that exists.
do
    local merged = {}
    for _, w in ipairs(BR.Config.Weapons) do merged[#merged + 1] = w end
    for _, w in ipairs(BR.Config.AirdropWeapons) do merged[#merged + 1] = w end

    local cfg = { prices = { rpg = 450, minigun = 500 }, ammo = {} }
    for id, p in pairs(G.prices) do cfg.prices[id] = p end

    local r, rj = S.catalogue(cfg, {
        weapons     = merged,
        airdropOnly = BR.Config.AirdropWeapons,
    })

    local sold = {}
    for _, w in ipairs(BR.Config.AirdropWeapons) do
        if S.rowById(r, w.id) then sold[#sold + 1] = w.id end
    end
    ok(#sold == 0,
        'a merged weapon table still sells no RPG, launcher, railgun or minigun',
        #sold > 0 and table.concat(sold, ', ') or nil)

    local named = {}
    for _, x in ipairs(rj) do
        if x.why == 'airdrop-only' then named[#named + 1] = x.id end
    end
    ok(#named == 4,
        'and all four are REPORTED rather than silently skipped -- reaching '
            .. 'that branch at all is a bug worth a console line', #named)

    -- WITHOUT THE GUARD TABLE the same call would sell them. This is the
    -- discriminator: it proves the assertion above is the guard working and not
    -- the fixture happening to contain nothing.
    local r2 = S.catalogue(cfg, { weapons = merged })
    ok(S.rowById(r2, 'rpg') ~= nil,
        'and with no guard table passed, the merged list DOES sell one -- so '
            .. 'the check above is the guard and not an accident')
end

-- ---------------------------------------------------------------------------
describe('the ammo half of the derivation, on fixtures')
-- ---------------------------------------------------------------------------
do
    local cfg = {
        prices = {},
        ammo = { light = { price = 30 }, heavy = { price = 50 }, smg = {} },
    }
    local pickups = {
        light = { label = 'Light Ammo', amount = 36 },
        heavy = { label = 'Heavy Ammo', amount = 12 },
        smg   = { label = 'SMG Ammo',   amount = 60 },
    }

    local r, rj = S.catalogue(cfg, {
        ammoOrder   = { 'light', 'smg', 'heavy' },
        ammoPickups = pickups,
    })

    ok(#r == 2 and r[1].id == 'ammo_light' and r[2].id == 'ammo_heavy',
        'the priced pools are stocked, in AmmoOrder order', #r)
    ok(#rj == 1 and rj[1].id == 'ammo_smg' and rj[1].why == 'no price',
        'and an unpriced pool is dropped by name',
        #rj > 0 and (rj[1].id .. ': ' .. rj[1].why) or '(nothing rejected)')

    -- A POOL WITH A PRICE AND NO SIZE IS THE ONE OUTCOME WORSE THAN NOT SELLING
    -- IT: a known cost for an unknown quantity.
    local sizeless = { prices = {}, ammo = { light = { price = 30 } } }
    local r2, rj2 = S.catalogue(sizeless, {
        ammoOrder = { 'light' }, ammoPickups = {},
    })
    ok(#r2 == 0 and #rj2 == 1 and rj2[1].why == 'no bundle size',
        'a pool with a price and no bundle is dropped, not sold blind',
        #rj2 > 0 and rj2[1].why or nil)

    ok(S.ammoBundle(nil, 'light', pickups) == 36,
        'and the derivation needs no config at all to answer')
    ok(S.ammoBundle(cfg, 'light', nil) == nil,
        'while no pickups and no override is no answer, rather than a guess')
end

-- ---------------------------------------------------------------------------
describe('inert rather than broken')
-- ---------------------------------------------------------------------------
--
-- BR.Config.Rescue.points' rule, applied a third time. An empty or disabled
-- config must produce a match with no gun shops in it -- no clerks, no prompt,
-- no purchase handler doing anything, and above all no error.
do
    ok(S.enabled(nil) == false and S.enabled({}) == false,
        'no config at all is a shop that does not exist')
    ok(S.enabled({ stores = {} }) == false, 'and neither is an empty store list')
    ok(S.enabled({ enabled = false, stores = G.stores }) == false,
        'and the flag turns eleven live counters off')
    ok(S.storeCount(nil) == 0 and S.storeCount({}) == 0,
        'counting an absent config is zero, not an error')

    local r, rj = S.catalogue(nil, nil)
    ok(#r == 0 and #rj == 0, 'and a nil config builds an empty catalogue')

    local r2 = S.catalogue({ prices = {} }, { weapons = 'not a table' })
    ok(#r2 == 0, 'as does a source that is not a table')
end

-- ---------------------------------------------------------------------------
describe('duplicate ids')
-- ---------------------------------------------------------------------------
do
    local R = BR.Rarity
    local weapons = {
        { id = 'twin', rarity = R.RARE, damage = 20 },
        { id = 'twin', rarity = R.EPIC, damage = 30 },
    }
    local r, rj = S.catalogue({ prices = { twin = 120 }, ammo = {} },
                              { weapons = weapons })
    ok(#r == 1 and #rj == 1 and rj[1].why == 'duplicate id',
        'the first row wins and the second is reported',
        #rj > 0 and rj[1].why or nil)

    local s, sr = S.stores({ stores = {
        { id = 'a', x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        { id = 'a', x = 9.0, y = 0.0, z = 0.0, heading = 0.0 },
    } })
    ok(#s == 1 and #sr == 1 and sr[1].why == 'duplicate id',
        'and the same rule holds for two counters with one id')
end

-- ---------------------------------------------------------------------------
describe('a store row that is not usable is dropped and named')
-- ---------------------------------------------------------------------------
do
    local cases = {
        { nil,                                                  'not a table' },
        { { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },          'no id' },
        { { id = 'a', y = 0.0, z = 0.0, heading = 0.0 },         'no coordinates' },
        { { id = 'a', x = 0.0, y = 0.0, z = 0.0 },               'no heading' },
    }
    for _, c in ipairs(cases) do
        local okv, why = S.validateStore(c[1])
        ok(okv == false and why == c[2],
            'refused: ' .. c[2], tostring(why))
    end

    local okv = S.validateStore({ id = 'a', x = 0.0, y = 0.0, z = 0.0,
                                  heading = 0.0 })
    ok(okv == true, 'and a minimal row with no flags is fine')
end

-- ---------------------------------------------------------------------------
describe('may this player buy, right now')
-- ---------------------------------------------------------------------------
--
-- THE CLIENT ASKS AND NEVER DECIDES. Every term is resolved server-side, which
-- is server/market.lua's rule for the storefront and BR.ShopSolve.canBuy's for
-- the showroom.
do
    local Refusal = S.Refusal
    local function state(over)
        local st = {
            on          = true,
            matchState  = BR.MatchState.PLAYING,
            playerState = BR.PlayerState.ALIVE,
            atCounter   = true,
            row         = rows[1],
            balance     = 1000,
            price       = 150,
        }
        for k, v in pairs(over or {}) do st[k] = v end
        return st
    end

    local okv, why = S.canBuy(state())
    ok(okv == true and why == nil, 'the happy case buys')

    okv, why = S.canBuy(state({ on = false }))
    ok(okv == false and why == Refusal.OFF, 'a shop that is off sells nothing', why)

    okv, why = S.canBuy(state({ matchState = BR.MatchState.WARMUP }))
    ok(okv == false and why == Refusal.STATE,
        'the counter is closed outside a live match', why)

    okv, why = S.canBuy(state({ playerState = BR.PlayerState.OUT }))
    ok(okv == false and why == Refusal.STATE,
        'and closed to a player who is out, even while the match runs', why)

    -- BOTH CLOCKS, which is the shape of bug that let a downed player use the
    -- inventory: checking the match and not the player, or the reverse.
    okv, why = S.canBuy(state({ playerState = BR.PlayerState.DBNO }))
    ok(okv == false and why == Refusal.STATE, 'and to a downed one', why)

    okv, why = S.canBuy(state({ atCounter = false }))
    ok(okv == false and why == Refusal.NOTAT,
        'a player who is not at a counter cannot shop from the map', why)

    -- BUILT BY HAND RATHER THAN THROUGH `state`, and the reason is a Lua trap
    -- worth naming: `state({ row = nil })` sets nothing at all, because a nil
    -- value is not a key and pairs() never visits it. The override helper cannot
    -- express "remove this field", so this case does not use it -- the first
    -- version of this test did, passed, and was asserting the happy path twice.
    local noRow = state()
    noRow.row = nil
    okv, why = S.canBuy(noRow)
    ok(okv == false and why == Refusal.NOROW,
        'and an id that is not for sale is refused before the money is looked '
            .. 'at', why)

    okv, why = S.canBuy(state({ balance = 149, price = 150 }))
    ok(okv == false and why == Refusal.AFFORD, 'one Volt short is short', why)

    okv = S.canBuy(state({ balance = 150, price = 150 }))
    ok(okv == true,
        'and spending your last Volt is a purchase, not an overdraft')

    okv, why = S.canBuy(nil)
    ok(okv == false and why == Refusal.OFF, 'nothing at all is refused, not thrown')

    ok(S.shortfall(149, 150) == 1 and S.shortfall(1000, 150) == 0
       and S.shortfall(nil, 150) == 150,
        'the shortfall never goes negative and survives a nil balance')
end

-- ---------------------------------------------------------------------------
describe('build() is idempotent, because both ends call it')
-- ---------------------------------------------------------------------------
do
    local a = select(1, G.build())
    local b = select(1, G.build())
    ok(a == b, 'the client and the server share one catalogue table')
    ok(#a == 30, 'and a second call does not double it', #a)
end

-- ---------------------------------------------------------------------------
describe('a counter with nobody behind it is not a counter')
-- ---------------------------------------------------------------------------
--
-- The fifth parameter of `nearest`. A clerk is a CLIENT-LOCAL ped, so whether
-- one is standing is a fact about one machine -- and offering a price at a
-- counter where the model never streamed is a price for something the player
-- cannot see. BR.ShopSolve.nearest grew the identical parameter for the
-- identical reason.
do
    local pillbox
    for _, s in ipairs(stores) do if s.id == 'pillbox' then pillbox = s end end

    local fixture = {
        { id = 'a', x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        { id = 'b', x = 3.0, y = 0.0, z = 0.0, heading = 0.0 },
    }

    local at = S.nearest(fixture, 2.0, 0.0, 5.0, nil)
    ok(at ~= nil and at.id == 'b',
        'no filter accepts every counter -- which is what the SERVER passes, '
            .. 'because it has no clerk and never had one')

    at = S.nearest(fixture, 2.0, 0.0, 5.0, function(s) return s.id ~= 'b' end)
    ok(at ~= nil and at.id == 'a',
        'the nearer counter having no clerk offers the next one rather than '
            .. 'offering nothing')

    at = S.nearest(fixture, 2.0, 0.0, 5.0, function() return false end)
    ok(at == nil, 'and no clerk anywhere in reach is no counter at all')

    -- 0 IS TRUTHY IN LUA, so the filter's answer is compared rather than
    -- tested. A predicate that handed back a raw FiveM BOOL would otherwise
    -- make every counter present, including the ones with nobody at them.
    at = S.nearest(fixture, 2.0, 0.0, 5.0, function() return 1 end)
    ok(at == nil, 'a raw 1 is not `true`, and is not read as one')

    at = S.nearest(fixture, 2.0, 0.0, 5.0, 'not a function')
    ok(at == nil, 'a filter that is not callable answers nil rather than '
        .. 'throwing inside a 10 Hz loop')

    -- THE FILTER IS ASKED ONLY ABOUT WHAT IS IN REACH. It runs on the TICK band
    -- and the client's version of it asks the engine whether an entity exists,
    -- so asking it about all eleven counters ten times a second would be eleven
    -- native calls to answer a question about one.
    local asked = {}
    S.nearest(stores, pillbox.x, pillbox.y, G.reachM, function(s)
        asked[#asked + 1] = s.id
        return true
    end)
    ok(#asked == 1 and asked[1] == 'pillbox',
        'the filter is asked only about counters already inside the reach',
        table.concat(asked, ', '))
end

-- ---------------------------------------------------------------------------
describe('the clerk is built and taken down on DISTANCE, with a band')
-- ---------------------------------------------------------------------------
--
-- Eleven buildings over 51 km^2, ten of which a given player never enters. The
-- warmup showroom has no distance term because it is one pad everybody walks
-- through; this cannot copy that, and the failure a single radius produces is a
-- ped built and deleted once a second for as long as somebody stands on it.
do
    local st = { id = 'h', x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }

    ok(S.wantsClerk(st, 50.0, 0.0, 60.0, 90.0, false) == true,
        'inside the build radius with nobody there, build one')
    ok(S.wantsClerk(st, 70.0, 0.0, 60.0, 90.0, false) == false,
        'inside the BAND with nobody there, do not')
    ok(S.wantsClerk(st, 70.0, 0.0, 60.0, 90.0, true) == true,
        '...but a clerk already standing in the band stays')
    ok(S.wantsClerk(st, 95.0, 0.0, 60.0, 90.0, true) == false,
        'and past the keep radius he goes')

    -- THE FLICKER THIS EXISTS TO PREVENT, ASSERTED DIRECTLY: standing on the
    -- build radius, both answers are the same, so nothing changes on any pass.
    ok(S.wantsClerk(st, 60.0, 0.0, 60.0, 90.0, false) == true
       and S.wantsClerk(st, 60.0, 0.0, 60.0, 90.0, true) == true,
        'standing exactly on the build radius does not build and delete a ped '
            .. 'once a second')

    ok(S.wantsClerk(st, 10.0, 0.0, nil, nil, false) == false,
        'no radius is no clerk, rather than a clerk everywhere')
    ok(S.wantsClerk(nil, 0.0, 0.0, 60.0, 90.0, false) == false
       and S.wantsClerk(st, nil, 0.0, 60.0, 90.0, false) == false,
        'and a missing anything answers false rather than throwing')

    -- THE SHIPPED PAIR IS A BAND. A config where keep <= build is the flicker
    -- back again, and the solver deliberately does not clamp it -- so this is
    -- the only place that would notice.
    ok((tonumber(G.clerkKeepM) or 0) > (tonumber(G.clerkBuildM) or 0),
        'the shipped radii are a band and not a line',
        ('build %s keep %s'):format(tostring(G.clerkBuildM),
                                    tostring(G.clerkKeepM)))
    ok((tonumber(G.clerkBuildM) or 0) > (tonumber(G.reachM) or 0),
        'and a clerk is standing there well before a player is close enough '
            .. 'to be offered the counter')
end

-- ---------------------------------------------------------------------------
describe('the clerk height is PROBED and the table never wins by default')
-- ---------------------------------------------------------------------------
--
-- This is the rule config/gunshop.lua's longest block is about, and it is the
-- one thing about the clerk that a test can hold: the sources disagree by up to
-- about 1.1m on whether the tabulated z is the interior floor or a standing
-- ped's center, so the engine is asked and the table is only a starting point.
do
    local pillbox
    for _, s in ipairs(stores) do if s.id == 'pillbox' then pillbox = s end end

    -- ═══ WHERE THE PROBE STARTS ═══
    ok(S.probeStart(G, pillbox) == pillbox.z + G.probeLiftM,
        'the probe starts ABOVE the anchor -- the native answers with the '
            .. 'highest ground BELOW the point it is handed')
    ok(G.probeLiftM > 1.1,
        'and the lift clears the worst case the two source tables can '
            .. 'disagree by', G.probeLiftM)
    ok(G.probeLiftM < 3.0,
        '...while staying under an interior ceiling, because a probe started '
            .. 'over the roof answers with the roof', G.probeLiftM)

    local over = { id = 'x', x = 0.0, y = 0.0, z = 10.0, heading = 0.0,
                   probeFromM = 4.0 }
    ok(S.probeStart(G, over) == 14.0,
        "a store's own probeFromM beats the global lift")
    ok(S.probeStart(G, nil) == nil
       and S.probeStart(G, { id = 'y', x = 0.0, y = 0.0, heading = 0.0 }) == nil,
        'and a store with no z has no probe to start')

    -- ═══ THE THREE ANSWERS, IN ORDER ═══
    local z, src = S.clerkZ(G, pillbox, true, 28.5)
    ok(z == 28.5 and src == 'probe',
        'when the engine answers, the engine wins')

    z, src = S.clerkZ(G, pillbox, false, nil)
    ok(z == pillbox.z and src == 'anchor',
        'when it does not, the raw anchor is used AND the ledger says so -- a '
            .. 'clerk who may be a metre out beats a counter with nobody at it')

    local pinned = { id = 'o', x = 0.0, y = 0.0, z = 10.0, heading = 0.0,
                     zOverride = 99.0 }
    z, src = S.clerkZ(G, pinned, true, 5.0)
    ok(z == 99.0 and src == 'override',
        'the escape hatch beats the probe, which is what an escape hatch is')

    -- 0 IS TRUTHY IN LUA AND GET_GROUND_Z_FOR_3D_COORD IS DECLARED BOOL. The
    -- caller must put the first return through isTrue; handed a raw 1 this
    -- falls back to the anchor rather than trusting a value it cannot vouch
    -- for, and handed a raw 0 it cannot possibly read a refusal as an answer.
    z, src = S.clerkZ(G, pillbox, 1, 28.5)
    ok(z == pillbox.z and src == 'anchor',
        'a raw 1 is not `true` -- the caller isTrue()s it or gets the anchor')
    z, src = S.clerkZ(G, pillbox, 0, 28.5)
    ok(src == 'anchor', 'and a raw 0 can never be read as an answer')

    z, src = S.clerkZ(G, pillbox, true, nil)
    ok(z == pillbox.z and src == 'anchor',
        'a probe that said yes and handed back nothing is not an answer either')

    -- ═══ NOTHING IN THE SHIPPED CONFIG PINS A HEIGHT ═══
    local pinnedIds = {}
    for _, s in ipairs(G.stores) do
        if s.zOverride ~= nil then pinnedIds[#pinnedIds + 1] = s.id end
    end
    ok(#pinnedIds == 0,
        'no store ships with an authored clerk height -- the slot exists for '
            .. 'the one interior a playtest proves the probe wrong at',
        table.concat(pinnedIds, ', '))
end

-- ---------------------------------------------------------------------------
describe('where the clerk stands, relative to the counter')
-- ---------------------------------------------------------------------------
do
    local st = { id = 'n', x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }

    local x, y, z, h = S.clerkAt(G, st, 5.0)
    ok(math.abs(x) < 1e-9 and math.abs(y) < 1e-9 and z == 5.0 and h == 0.0,
        'the shipped offset is zero, so he stands on the anchor facing the '
            .. "counter's own heading -- which is where the two source "
            .. 'resources this survey came from put their shop peds')

    -- GTA HEADINGS ARE DEGREES CLOCKWISE FROM NORTH and forward is
    -- (-sin h, cos h). Asserted rather than assumed, because a sign error here
    -- would put every clerk on the wrong side of every counter and would look
    -- exactly like a bad survey.
    local cfg = { clerkOffsetM = 2.0, clerkFaceDeg = 180.0 }
    x, y = S.clerkAt(cfg, st, 0.0)
    ok(math.abs(x) < 1e-9 and math.abs(y - 2.0) < 1e-9,
        'at heading 0 the offset is spent along +Y', ('%.4f, %.4f'):format(x, y))

    -- HEADING 90 IN GTA FACES WEST, not east. Forward is (-sin h, cos h), so a
    -- quarter turn is -X -- and getting that sign backwards would put every
    -- clerk on the far side of every counter while looking, in a diff, exactly
    -- like the correct arithmetic. client/dui.lua's `levelBasis` records the
    -- same convention for the entity form of it.
    st.heading = 90.0
    x, y = S.clerkAt(cfg, st, 0.0)
    ok(math.abs(x + 2.0) < 1e-6 and math.abs(y) < 1e-6,
        'and at heading 90 along -X, which is west', ('%.4f, %.4f'):format(x, y))

    local _, _, _, hh = S.clerkAt(cfg, st, 0.0)
    ok(hh == 270.0, 'the facing offset is added to the counter heading', hh)

    st.heading = 270.0
    _, _, _, hh = S.clerkAt(cfg, st, 0.0)
    ok(hh == 90.0, '...and wraps rather than running past 360', hh)

    ok(select(1, S.clerkAt(G, nil, 1.0)) == nil
       and select(1, S.clerkAt(G, { id = 'z' }, 1.0)) == nil,
        'a store with no coordinates places nobody')
end

-- ---------------------------------------------------------------------------
describe('how a row is named on the shelf, and the one mark that is not his')
-- ---------------------------------------------------------------------------
do
    local shelf = select(1, G.build())
    local byId = {}
    for _, r in ipairs(shelf) do byId[r.id] = r end

    ok(S.menuLabel(byId.carbinerifle) == 'Carbine Rifle',
        "a weapon is named by config/weapons.lua's own label and nothing is "
            .. 'added to it', S.menuLabel(byId.carbinerifle))
    ok(S.menuLabel(byId.heavysniper) == 'Heavy Sniper',
        'including the legendary end of the shelf',
        S.menuLabel(byId.heavysniper))

    -- THE QUANTITY IS THE ONE THING THE LABEL CANNOT SAY BY ITSELF. 50 Volts is
    -- dear for twelve rounds and cheap for sixty, and config/gunshop.lua's own
    -- marked block asks the owner to judge exactly that -- which he cannot do
    -- from a shelf that does not say which it is.
    ok(S.menuLabel(byId.ammo_smg) == 'SMG Ammo x60',
        'an ammo row says how many rounds one purchase hands over',
        S.menuLabel(byId.ammo_smg))
    ok(S.menuLabel(byId.ammo_heavy) == 'Heavy Ammo x12',
        'and the count is the ROW\'S OWN stack, so it tracks the bundle rule '
            .. 'rather than a number typed here', S.menuLabel(byId.ammo_heavy))

    -- THE COUNT COMES FROM THE STACK AND NOWHERE ELSE, so pinning a bundle in
    -- config moves the shelf with it and cannot leave the label behind.
    for _, r in ipairs(shelf) do
        if r.kind == BR.ItemKind.AMMO then
            local shown = S.menuLabel(r):match('x(%d+)$')
            ok(shown ~= nil and tonumber(shown) == r.stack.count,
                ('the %s shelf label quotes its own stack count'):format(r.id),
                S.menuLabel(r))
        end
    end

    ok(S.menuLabel(nil) == '' and S.menuLabel('nope') == '',
        'and anything that is not a row is named nothing rather than throwing')
end

-- ---------------------------------------------------------------------------
describe('the wiring that had no caller until br_core grew two files')
-- ---------------------------------------------------------------------------
--
-- BR.Config.Gunshop.build() shipped with NO call sites, deliberately -- the data
-- layer landed alone. It is a function rather than a loop at the bottom of the
-- config because br_lib's fxmanifest expands `config/*.lua` as a glob and
-- `gunshop` sorts before `weapons`, so a catalogue derived at that file's own
-- load is an empty shop with no error anywhere.
--
-- THIS IS THE GATE THAT KEEPS IT CALLED. A refactor that dropped either call
-- site would leave a shop that is silently empty on one side.
do
    --- COMMENT LINES ARE STRIPPED FIRST, AND THAT IS NOT TIDINESS.
    ---
    --- tools/verify.sh's own gates do exactly this and say why: this project's
    --- prose QUOTES the identifiers being searched for, because the whole point
    --- of those paragraphs is to explain a rule about them. client/gunshop.lua's
    --- header explains that a ScaleformUI menu holds input with
    --- DisableAllControlActions rather than SetNuiFocus, and server/gunshop.lua's
    --- explains why the roster's sampled position is read rather than a fresh
    --- GetPlayerPed. A check that counted prose would fail on the paragraph
    --- explaining why the rule exists -- which is the fastest possible route to
    --- the paragraph being deleted.
    ---
    --- CRUDE ON PURPOSE, line by line, which can also blank a `--` inside a
    --- string literal. Every assertion below is a presence check on an
    --- identifier, so that costs nothing.
    --- @param src string
    --- @return string
    local function code(src)
        local out = {}
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do
            out[#out + 1] = line:gsub('%-%-.*$', '')
        end
        return table.concat(out, '\n')
    end

    local cli = code(readFile(ROOT .. 'br_core/client/gunshop.lua'))
    local srv = code(readFile(ROOT .. 'br_core/server/gunshop.lua'))

    ok(cli ~= '' and srv ~= '', 'both halves of the counter exist')

    ok(cli:find('BR.Config.Gunshop.build()', 1, true) ~= nil,
        'the client builds the catalogue at its own resource start')
    ok(srv:find('BR.Config.Gunshop.build()', 1, true) ~= nil,
        'and so does the server')
    ok(cli:find("AddEventHandler('onClientResourceStart'", 1, true) ~= nil,
        '...at resource start, not at config load')
    ok(srv:find("AddEventHandler('onResourceStart'", 1, true) ~= nil,
        'on the server too')

    -- ═══ THE CLIENT AUTHORS NO HEIGHT ═══
    ok(cli:find('GetGroundZFor_3dCoord', 1, true) ~= nil,
        'the client asks the engine where the floor is')
    ok(cli:find('BR.GunshopSolve.clerkZ', 1, true) ~= nil,
        '...and spends the answer through the solver, where a test can reach '
            .. 'the rule')
    ok(cli:find('placed%[store%.id%]') ~= nil,
        'and writes a per-store ledger of what happened')
    ok(cli:find("RegisterCommand('brgunshop'", 1, true) ~= nil,
        'which a dev command prints, so one playtest round turns eleven '
            .. 'guesses into eleven numbers')

    -- ═══ THE RULES tools/verify.sh CANNOT SEE FROM ITS OWN GATES ═══
    --
    -- br_ui/client/nui.lua is the only file allowed to touch NUI focus, and
    -- client/sfx.lua is the only file allowed to name a GTA set/name pair. A
    -- ScaleformUI menu holds input with DisableAllControlActions instead, which
    -- is a different mechanism entirely and must stay one.
    ok(cli:find('SetNuiFocus', 1, true) == nil
       and cli:find('SendNUIMessage', 1, true) == nil,
        'the menu never touches the NUI focus stack')
    ok(cli:find('PlaySoundFrontend', 1, true) == nil,
        'and plays its cue by KEY through BR.Sfx rather than naming a sound')
    ok(cli:find('BR.Sfx.play(G.cue)', 1, true) ~= nil,
        'the cue key comes out of config, so /brsfx can still audition it')

    -- ═══ THE SERVER SPEAKS EXACTLY ONE SENTENCE, AND IT IS NOT ITS OWN ═══
    --
    -- The owner has written no player-facing copy for this feature. `afford` is
    -- the one refusal with an existing sentence and it is the market's, spoken
    -- at the one funnel every shortfall in the game reaches.
    ok(srv:find('BR.Market.tellShortfall', 1, true) ~= nil,
        'the server refuses a shortfall in the market\'s own words')
    ok(srv:find('BR.Server.notify', 1, true) == nil,
        '...and says nothing else to anybody -- no toast was ever written for '
            .. 'this counter')
    ok(srv:find('BR.Roster.get', 1, true) ~= nil
       and srv:find('GetPlayerPed', 1, true) == nil,
        "the position is the roster's sampled one, never a fresh GetPlayerPed "
            .. '-- which returns 0 for every player when handed a numeric src')

    -- ═══ THE COLORS ARE OURS, AND EIGHT DIGITS DEEP ═══
    --
    -- ScaleformUI's hex parser reads characters 2-3 as ALPHA. A six-digit code
    -- is not rejected: it is misread, and then throws several calls later
    -- inside ToArgb with a message about nil arithmetic, nowhere near the line
    -- that caused it.
    local menu = readFile(ROOT .. 'br_core/client/menu.lua')
    local css  = readFile('ui-src/src/index.css')
    ok(menu ~= '', 'the theme helper exists')

    local accent = menu:match("ACCENT_HEX%s*=%s*'#(%x+)'")
    local goldc  = menu:match("GOLD_HEX%s*=%s*'#(%x+)'")
    ok(accent ~= nil and #accent == 8,
        'the accent is eight digits, alpha first', tostring(accent))
    ok(goldc ~= nil and #goldc == 8,
        'and so is the gold', tostring(goldc))

    -- AND THEY ARE STILL index.css's. ui-src is where a color in this game is
    -- authored; a scaleform cannot read a cascade, so these two are the one Lua
    -- copy and this is what stops them drifting from it.
    -- THE HYPHENS ARE ESCAPED. `-` is Lua's lazy quantifier, so a raw
    -- `--color-volts` is not the string it looks like -- it is a pattern that
    -- matches almost nothing, and this assertion would have passed for the
    -- wrong reason on the day the color drifted.
    ok(accent ~= nil and css:lower():find('%-%-color%-royale%-accent:%s*#'
        .. accent:sub(3):lower()) ~= nil,
        'the accent still equals --color-royale-accent in index.css',
        tostring(accent))
    ok(goldc ~= nil and css:lower():find('%-%-color%-volts:%s*#'
        .. goldc:sub(3):lower()) ~= nil,
        'and the gold still equals --color-volts', tostring(goldc))

    ok(cli:find('#%x%x%x%x%x%x') == nil,
        'and the shop file itself names no color at all -- the palette is '
            .. 'applied in one place')
end

-- ---------------------------------------------------------------------------
-- The server half, stood up for real
-- ---------------------------------------------------------------------------
--
-- ═══ WHY A FIXTURE HERE RATHER THAN A SOURCE GREP ═══
--
-- Everything above this line is arithmetic. The three claims that fund this
-- feature's security are not: a player cannot buy what they cannot afford,
-- cannot buy from across the map, and cannot buy anything that is not in the
-- catalogue. Each of those is a PATH through br_core/server/gunshop.lua -- an
-- ordering of a resolve, a predicate, a charge and a callback -- and a grep can
-- only see that the words are present, not that they run in that order.
--
-- tools/test_shop.lua stands the warmup showroom's server file up the same way
-- and for the same reason. This is that pattern, applied to the counter.
do
    local handlers = {}
    local sent, charged, notices, given, dropped = {}, {}, {}, {}, {}
    local roster, matches = {}, {}

    function AddEventHandler(name, fn) handlers[name] = fn end
    function RegisterNetEvent() end
    function GetCurrentResourceName() return 'br_core' end
    function TriggerClientEvent(name, src, payload)
        sent[#sent + 1] = { name = name, src = src, payload = payload }
    end

    BR.Server = {
        matchOf = function(src)
            local e = roster[src]
            return e and matches[e.matchId] or nil
        end,
    }
    BR.Roster = { get = function(src) return roster[src] end }

    --- THE CHARGE IS A DYNAMODB ROUND TRIP AND THE STUB CAN HOLD IT OPEN.
    ---
    --- `hold` is what makes the post-charge gate reachable: the whole point of
    --- re-reading the match inside the callback is that up to six seconds pass,
    --- and a stub that answered synchronously could never produce those seconds.
    BR.Market = {
        balances = {},
        hold = false,
        held = {},
        balanceOf = function(src) return BR.Market.balances[src] or 0 end,
        tellShortfall = function(src, price)
            notices[#notices + 1] = { src = src, price = price }
        end,
        charge = function(src, amount, reason, done)
            done = done or function() end
            local function settle()
                if (BR.Market.balances[src] or 0) < amount then
                    BR.Market.tellShortfall(src, amount)
                    done(false, 'poor')
                    return
                end
                BR.Market.balances[src] = BR.Market.balances[src] - amount
                charged[#charged + 1] =
                    { src = src, amount = amount, reason = reason }
                done(true, nil, BR.Market.balances[src])
            end
            if BR.Market.hold then
                BR.Market.held[#BR.Market.held + 1] = settle
            else
                settle()
            end
        end,
    }

    local function settleCharges()
        local due = BR.Market.held
        BR.Market.held = {}
        for _, fn in ipairs(due) do fn() end
    end

    local bagFull = false
    BR.Inv = {
        give = function(src, stack, opts)
            given[#given + 1] = { src = src, stack = stack, opts = opts }
            if bagFull then return false, nil, 'carrymax' end
            return true, nil, nil
        end,
    }
    BR.Loot = {
        dropForPlayer = function(src, stack)
            dropped[#dropped + 1] = { src = src, stack = stack }
        end,
    }

    -- BR.Net, which the handler registers itself under.
    do
        local chunk = loadfile(ROOT .. 'br_lib/shared/protocol.lua')
        if not chunk then
            print('\27[31mload error\27[0m protocol.lua')
            os.exit(1)
        end
        chunk()
    end

    --- Run something with the console turned off. `resolve()` prints a boot
    --- line and every refusal prints one; a suite that let them through would
    --- bury its own failures.
    local realPrint = print
    local function quiet(fn, ...)
        _G.print = function() end
        local okc, err = pcall(fn, ...)
        _G.print = realPrint
        if not okc then error(err, 0) end
    end

    do
        local chunk = loadfile(ROOT .. 'br_core/server/gunshop.lua')
        if not chunk then
            print('\27[31mload error\27[0m server/gunshop.lua')
            os.exit(1)
        end
        chunk()
    end
    quiet(handlers['onResourceStart'], 'br_core')

    local pillbox
    for _, s in ipairs(stores) do if s.id == 'pillbox' then pillbox = s end end

    local function reset()
        sent, charged, notices, given, dropped = {}, {}, {}, {}, {}
        roster, matches = {}, {}
        BR.Market.balances = {}
        BR.Market.hold, BR.Market.held = false, {}
        bagFull = false
    end

    --- One player, standing at the Pillbox Hill counter, in a live match.
    local function player(src, opts)
        opts = opts or {}
        matches[1] = { id = 1, state = opts.matchState or BR.MatchState.PLAYING }
        roster[src] = {
            matchId = 1,
            state = opts.state or BR.PlayerState.ALIVE,
            -- THE SAMPLED POSITION, WHICH IS A REAL FIELD. server/roster.lua
            -- writes it on every position pass and every server-side rule in
            -- this project reads it rather than taking a fresh GetPlayerPed --
            -- which returns 0 for every player when handed a numeric src.
            pos = opts.pos
                or { x = pillbox.x, y = pillbox.y, z = pillbox.z },
        }
        BR.Market.balances[src] = opts.balance or 5000
    end

    local function buy(src, id, extra)
        local payload = { id = id }
        if extra then for k, v in pairs(extra) do payload[k] = v end end
        _G.source = src
        quiet(handlers[BR.Net.GUNSHOP_BUY], payload)
    end

    local function boughtFor(src)
        for _, s in ipairs(sent) do
            if s.name == BR.Net.GUNSHOP_BOUGHT and s.src == src then
                return s.payload
            end
        end
        return nil
    end

    -- -----------------------------------------------------------------------
    describe('buying at the counter, for real')
    -- -----------------------------------------------------------------------
    reset()
    player(10)
    buy(10, 'carbinerifle')

    ok(#charged == 1 and charged[1].amount == 115,
        'the price comes off the ROW, never off anything the client sent',
        charged[1] and charged[1].amount)
    ok(#charged == 1 and charged[1].reason == 'gunshop:carbinerifle',
        'and the debit is labelled with the row, so a ledger line can be '
            .. 'traced back to a counter', charged[1] and charged[1].reason)
    ok(#given == 1 and given[1].stack.item == 'carbinerifle'
       and given[1].stack.kind == BR.ItemKind.WEAPON
       and given[1].stack.count == 1,
        "the goods are the ROW'S OWN stack -- the same table BR.RollLootStack "
            .. 'hands back for the same gun off the floor')
    -- ...BUT NOT THE CATALOGUE'S OWN TABLE. The catalogue is built once and
    -- memoised, so `row.stack` is one table shared by every purchase of that row
    -- for the life of the process. If the inventory or the loot system ever kept
    -- a reference, a magazine count written into one player's slot would be
    -- written into the shelf and handed to every subsequent buyer.
    do
        local shelfRow
        for _, r in ipairs(BR.Config.Gunshop.rows) do
            if r.id == 'carbinerifle' then shelfRow = r end
        end
        ok(#given == 1 and given[1].stack ~= shelfRow.stack,
            'and it is a COPY of that stack, not the shelf\'s own table')
    end

    ok(#given == 1 and given[1].opts and given[1].opts.quiet == true,
        'handed over QUIETLY: the purchase cue is about to play and two sounds '
            .. 'a frame apart for one event is the fault config/audio.lua is '
            .. 'about')
    ok(boughtFor(10) ~= nil and boughtFor(10).row == 'carbinerifle',
        'the client is told which row landed, so it plays the cue for what '
            .. 'arrived rather than for what it last asked about')
    ok(#notices == 0, 'and nothing at all is said to the player')
    ok(BR.Market.balances[10] == 5000 - 115,
        'the balance moves once', BR.Market.balances[10])

    -- -----------------------------------------------------------------------
    describe('a player cannot buy from across the map')
    -- -----------------------------------------------------------------------
    reset()
    player(11, { pos = { x = 0.0, y = 0.0, z = 70.0 } })
    buy(11, 'carbinerifle')
    ok(#charged == 0 and #given == 0,
        'standing a kilometre from the nearest counter buys nothing')

    -- THE CLIENT'S WORD IS NEVER ASKED FOR. A client that could assert "I am at
    -- a counter" could shop from the top of Mount Chiliad, so the payload is
    -- given every field it might hope to lie with.
    reset()
    player(12, { pos = { x = 0.0, y = 0.0, z = 70.0 } })
    buy(12, 'carbinerifle', {
        atCounter = true, store = 'pillbox',
        x = pillbox.x, y = pillbox.y, z = pillbox.z, price = 1,
    })
    ok(#charged == 0 and #given == 0,
        'and a payload that claims to be at a counter, names one, carries its '
            .. 'coordinates and quotes a price buys exactly as much: nothing')

    -- ...WHILE THE SERVER'S OWN RADIUS IS DELIBERATELY LOOSER THAN THE
    -- CLIENT'S. Positions are sampled at 4 Hz, so the newest reading can be
    -- 250ms old -- about 1.8m of sprint -- and refusing somebody standing at
    -- the till because their last sample was taken walking in is a refusal with
    -- no symptom.
    reset()
    player(13, { pos = { x = pillbox.x + 4.0, y = pillbox.y, z = pillbox.z } })
    buy(13, 'carbinerifle')
    ok(#charged == 1,
        'four metres out -- past the client reach, inside the server one -- is '
            .. 'still at the counter')

    reset()
    player(14, { pos = { x = pillbox.x + 40.0, y = pillbox.y, z = pillbox.z } })
    buy(14, 'carbinerifle')
    ok(#charged == 0, 'and forty metres out is not')

    -- -----------------------------------------------------------------------
    describe('a player cannot buy what is not on the shelf')
    -- -----------------------------------------------------------------------
    reset()
    player(15)
    for _, id in ipairs({ 'rpg', 'grenadelauncher', 'railgun', 'minigun',
                          'machete', 'grenade', 'pistol', 'microsmg', '',
                          'ammo_nonsense', 'car_runner' }) do
        buy(15, id)
    end
    ok(#charged == 0 and #given == 0,
        'the airdrop shelf, the melee list, the throwables, the common guns '
            .. 'and pure nonsense all buy nothing')

    -- THE AIRDROP FOUR ARE THE ONES THAT MATTER, and the reason is the rule at
    -- the top of config/gunshop.lua: they are in no rarity bucket, so no world
    -- roll can produce them, so the only way to hold one is to reach a supply
    -- drop. Selling one would be selling exactly the thing that cannot
    -- otherwise be found.
    reset()
    player(16)
    buy(16, 'rpg')
    ok(#charged == 0 and #notices == 0,
        'and an unknown row is refused in SILENCE -- no copy was ever written '
            .. 'for this counter, and inventing a refusal is the slop the '
            .. "owner's standing rule refuses")

    -- A PAYLOAD THAT IS NOT WHAT THE HANDLER EXPECTS RESOLVES TO "NO SUCH ROW"
    -- rather than reaching rowById as a type it refuses.
    reset()
    player(17)
    _G.source = 17
    quiet(handlers[BR.Net.GUNSHOP_BUY], nil)
    quiet(handlers[BR.Net.GUNSHOP_BUY], 'carbinerifle')
    quiet(handlers[BR.Net.GUNSHOP_BUY], { id = 12345 })
    quiet(handlers[BR.Net.GUNSHOP_BUY], { id = { 'carbinerifle' } })
    ok(#charged == 0 and #given == 0,
        'a nil, a string, a number and a table for an id all buy nothing and '
            .. 'none of them throws')

    -- -----------------------------------------------------------------------
    describe('a player cannot buy what they cannot afford')
    -- -----------------------------------------------------------------------
    reset()
    player(20, { balance = 114 })
    buy(20, 'carbinerifle')
    ok(#charged == 0 and #given == 0, 'one Volt short buys nothing')
    ok(#notices == 1 and notices[1].src == 20 and notices[1].price == 115,
        "...and it is the ONE refusal that speaks, in the market's own words, "
            .. 'through the one funnel that carries the shop.denied cue')

    reset()
    player(21, { balance = 115 })
    buy(21, 'carbinerifle')
    ok(#charged == 1 and #given == 1,
        'spending your last Volt at the counter is a purchase, not an '
            .. 'overdraft')
    ok(#notices == 0, 'and says nothing')

    -- -----------------------------------------------------------------------
    describe('the counter is open in a live match, to a living player')
    -- -----------------------------------------------------------------------
    for _, st in ipairs({ BR.MatchState.WARMUP, BR.MatchState.BUS,
                          BR.MatchState.ENDED }) do
        reset()
        player(30, { matchState = st })
        buy(30, 'carbinerifle')
        ok(#charged == 0,
            ('a match in %s sells nothing'):format(tostring(st)))
    end
    for _, st in ipairs({ BR.PlayerState.DBNO, BR.PlayerState.OUT,
                          BR.PlayerState.WARMUP }) do
        reset()
        player(31, { state = st })
        buy(31, 'carbinerifle')
        ok(#charged == 0,
            ('a player in %s buys nothing'):format(tostring(st)))
    end

    reset()
    buy(32, 'carbinerifle')
    ok(#charged == 0,
        'and somebody with no roster entry at all is refused rather than '
            .. 'throwing')

    -- -----------------------------------------------------------------------
    describe('ammo is bought by the pool, in one ground pickup')
    -- -----------------------------------------------------------------------
    reset()
    player(40)
    buy(40, 'ammo_smg')
    ok(#charged == 1 and charged[1].amount == 20,
        'the ammo price is the pool\'s', charged[1] and charged[1].amount)
    ok(#given == 1 and given[1].stack.kind == BR.ItemKind.AMMO
       and given[1].stack.item == BR.AmmoType.SMG
       and given[1].stack.count == 60,
        'and one purchase hands over exactly what one piece of ammo on the '
            .. 'floor is worth -- "a convenience with a fee", literally')

    -- NO PURCHASE LIMIT, which is the difference from the warmup showroom
    -- rather than an omission. A shop that sells one magazine per match is not
    -- a convenience.
    reset()
    player(41)
    buy(41, 'ammo_smg')
    buy(41, 'ammo_smg')
    buy(41, 'carbinerifle')
    ok(#charged == 3 and #given == 3,
        'three purchases at one counter is three purchases')

    -- -----------------------------------------------------------------------
    describe('a full bag drops rather than evaporating')
    -- -----------------------------------------------------------------------
    reset()
    player(50)
    bagFull = true
    buy(50, 'heavysniper')
    ok(#charged == 1 and #dropped == 1
       and dropped[1].stack.item == 'heavysniper',
        'what will not fit lands at their feet rather than being taken along '
            .. 'with the money')

    -- -----------------------------------------------------------------------
    describe('dying inside the DynamoDB round trip')
    -- -----------------------------------------------------------------------
    --
    -- A charge is up to six seconds and a player can be shot inside it. The
    -- item must not land in the bag of somebody who is no longer alive to hold
    -- it -- BR.Inv would wipe it at the next state change while the Volts
    -- stayed spent, which is the same loss with an extra step.
    reset()
    player(60)
    BR.Market.hold = true
    buy(60, 'heavysniper')
    ok(#charged == 0 and #given == 0,
        'nothing has happened while the write is in flight')
    roster[60].state = BR.PlayerState.OUT
    quiet(settleCharges)
    ok(#charged == 1, 'the debit still lands -- there is no refund path')
    ok(#given == 0 and boughtFor(60) == nil,
        '...and nothing is handed to a player who died inside it. It is loud '
            .. 'on the console, because it is the harshest thing this feature '
            .. 'does and it is invisible from inside the game')

    reset()
    player(61)
    BR.Market.hold = true
    buy(61, 'heavysniper')
    matches[1].state = BR.MatchState.ENDED
    quiet(settleCharges)
    ok(#given == 0, 'and the same if the MATCH ended inside the round trip')

    -- WALKING AWAY FROM THE TILL INSIDE THE ROUND TRIP IS NOT A REASON TO LOSE
    -- IT. The position is the one term here that is sampled rather than
    -- authoritative, and it was already checked before the money moved.
    reset()
    player(62)
    BR.Market.hold = true
    buy(62, 'heavysniper')
    roster[62].pos = { x = 0.0, y = 0.0, z = 70.0 }
    quiet(settleCharges)
    ok(#given == 1 and boughtFor(62) ~= nil,
        'a player who paid and then walked out of the shop still gets the gun')
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
