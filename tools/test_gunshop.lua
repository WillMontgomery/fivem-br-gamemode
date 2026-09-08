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

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
