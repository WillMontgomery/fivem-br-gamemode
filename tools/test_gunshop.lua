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
    'br_lib/shared/matchtag.lua', -- BR.MatchTag; the stock lines name their match
    -- THE SHIPPED WEAPON AND LOOT TABLES, NOT FIXTURES. These two files are the
    -- SUBJECT of half this suite: the catalogue is derived from them, so a
    -- fixture here would be a test that the derivation agrees with itself.
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/gunshop.lua',
    -- THE CURRENCY WORD AND THE PRICE FORMATTER, because the counter's two
    -- toasts are joined out of them and the joining is the thing under test.
    -- BR.GunshopSolve.poorToast and .boughtToast both call
    -- BR.ShopSolve.priceLine, which reads BR.Config.Market.currency through its
    -- caller -- so a suite without these would exercise the empty-currency
    -- branch and never the sentence a player reads.
    'br_lib/config/market.lua',
    'br_lib/shared/shop_solve.lua',
    'br_lib/shared/rng.lua',
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
describe('the ammunition separator is his word now, and it is recorded as his')
-- ---------------------------------------------------------------------------
--
-- ═══ THE RULE, IN HIS WORDS ═══
--
--   "please do not add any helper text to any pages on your own ever ... it
--    comes across as AI slop"
--
-- Every word a player reads at this counter is either his, typed as he typed
-- it, or derived from a table somebody owns. AMMO_GROUP was the one exception
-- for two days -- he asked for "separators in between that indicate the
-- category", three of the four groups take their word from BR.RarityInfo, and
-- the ammunition group has no table with a name in it -- so it stood as a
-- marked placeholder until he said what it should read.
--
-- ═══ AND HE SAID SO ON 2026-09-11 ═══
--
--   "The ammunition separator should read 'Ammo' and be no special color, same
--    color as the ammo item rows themselves."
--
-- SO WHAT THIS BLOCK CHECKS HAS TURNED OVER. It used to prove the flag was
-- still up; it now proves the RULING is written down where the string is, which
-- is the same job pointed the other way. A constant with no provenance beside it
-- is the thing this file has always been about: the next reader has to be able
-- to tell his word from ours without going and finding the issue.
do
    local raw = readFile(ROOT .. 'br_core/client/gunshop.lua')

    -- MATCHED ON ONE LINE'S WORTH, because the quotation is wrapped and never
    -- appears contiguously in the file.
    ok(raw:find("separator should read 'Ammo'", 1, true) ~= nil,
        'his 2026-09-11 wording is quoted at the constant, so `Ammo` is legibly '
            .. 'his rather than ours')
    ok(raw:find('same color as the ammo item rows themselves', 1, true) ~= nil,
        '...including the color half, which is the part that is a change rather '
            .. 'than a confirmation')

    -- AND THE FLAG IS DOWN, WHICH IS AN ASSERTION AND NOT AN ABSENCE OF ONE. A
    -- placeholder marker left standing over a string he has since typed is a
    -- false comment, and this file is where the last one was caught.
    ok(raw:find("AWAITING THE OWNER'S WORDING", 1, true) == nil,
        'and the placeholder marker is gone, because the thing it was flagging '
            .. 'is gone -- a marker over his own word would be a lie about who '
            .. 'wrote it')
    ok(raw:find('AMMO_GROUP below is a placeholder WE wrote', 1, true) == nil,
        '...and so is the line naming it as ours')

    -- ═══ THE FINDING THAT BLOCKED HIS EARLIER ANSWER IS STILL TRUE, AND STILL
    --     CHECKED ═══
    --
    -- His answer of earlier the same day -- "The `Ammo` separator should be
    -- simply the name of the category of rarity for the items listed below the
    -- separator" -- was a RULE rather than a word, and 503298c found it could
    -- not be carried out because ammunition has no rarity to name.
    --
    -- ⚠ THE ASSERTION BELOW STAYS, AND WHAT IT MEANS HAS CHANGED. His ruling is
    -- "ammunition has no rarity", not "ammunition has one now" -- so a rarity
    -- appearing in either config table is still a real change to what
    -- ammunition IS, and somebody should look at this surface when it happens.
    -- It is no longer a thing WAITING to happen.
    ok(raw:find('AMMUNITION STILL CARRIES NO RARITY', 1, true) ~= nil,
        'and the file still says so where the separator is decided, so the '
            .. 'premise his answer rests on is legible beside it')
    --
    -- ⚠ NOT A LOOK AT THE BUILT ROW. `BR.GunshopSolve` stamps every ammo row
    -- with BR.Rarity.COMMON as a structural convention -- shared/loot_gen.lua
    -- spends the rarity roll on picking a pool instead, and says so -- so the
    -- row always has the field and asking it would answer COMMON forever. The
    -- question is whether anybody AUTHORED one, which is a question about the
    -- config tables.
    local authored = {}
    for _, pool in ipairs(BR.Config.AmmoOrder or {}) do
        local shopRow = (G.ammo or {})[pool]
        if type(shopRow) == 'table' and shopRow.rarity ~= nil then
            authored[#authored + 1] = 'Gunshop.ammo.' .. tostring(pool)
        end
        local pickup = (BR.Config.AmmoPickups or {})[pool]
        if type(pickup) == 'table' and pickup.rarity ~= nil then
            authored[#authored + 1] = 'AmmoPickups.' .. tostring(pool)
        end
    end
    ok(#BR.Config.AmmoOrder == 5,
        'all five ammo pools were actually looked at, rather than a loop that '
            .. 'never ran agreeing with the claim',
        #BR.Config.AmmoOrder)
    ok(#authored == 0,
        'ammunition still carries no authored rarity anywhere, which is the '
            .. 'premise behind "Ammo" -- WHEN THIS GOES RED, ammunition has '
            .. 'become a thing with a rarity and somebody has to ASK HIM '
            .. 'whether the separator should say so. Do not rename it on this '
            .. 'test\'s authority: `Ammo` is his word and the last one he gave',
        #authored > 0 and table.concat(authored, ', ') or nil)

    -- AND EVERY OTHER STRING ON THIS SURFACE IS STILL ATTRIBUTED AT ITS
    -- DECLARATION, which is what the placeholder marker was a special case of.
    -- Attribution is the rule; the marker was only ever what it looked like
    -- while one string had none to give.
    ok(raw:find('"a line underneath PRESS TO OPEN"', 1, true) ~= nil,
        'the plate hint is still attributed to him at its declaration')
    ok(raw:find('"instead show Out of Stock"', 1, true) ~= nil,
        'and so is the out-of-stock line')
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

    -- ═══ THE SHELF, AND THE TWO WAYS `0` IS TRUTHY COULD RUIN IT ═══
    --
    -- Owner, 2026-09-09: "If an item is out of stock, the row should be locked
    -- and a price should not be shown". A sold-out row must never be sellable,
    -- and the trap is Lua's: `if st.stock then` is TRUE for a stock of zero, so
    -- an implementation that tested the number rather than comparing it would
    -- sell the gun that is not there and would look correct in a diff.
    okv, why = S.canBuy(state({ stock = 0 }))
    ok(okv == false and why == Refusal.STOCK,
        'a shelf with none left sells none', why)

    okv = S.canBuy(state({ stock = 1 }))
    ok(okv == true, 'the last one on the shelf is still for sale')

    -- nil IS NOT ZERO. Ammo is uncounted, and a match whose shelves have not
    -- been rolled yet is uncounted too. Both mean unlimited, and neither means
    -- empty.
    okv = S.canBuy(state({ stock = nil }))
    ok(okv == true, 'and an UNCOUNTED row -- which is what ammo is -- sells')

    -- ═══ THE SHELF OUTRANKS THE MONEY, AND THAT ORDER IS THE SENTENCE ═══
    --
    -- Somebody broke, standing in front of an empty shelf, is told the shelf is
    -- empty rather than told the price of a thing that is not for sale.
    okv, why = S.canBuy(state({ stock = 0, balance = 0 }))
    ok(why == Refusal.STOCK,
        'a broke player at an empty shelf is told about the shelf', why)

    -- ═══ A FULL AMMO POOL, WHICH USED TO TAKE THE VOLTS ═══
    --
    -- Owner, 2026-09-09: "If someone is already carrying the max of an ammo ...
    -- reject the purchase". Before this the purchase went through, the pool
    -- clamped, and the bundle landed on the floor -- server/gunshop.lua's
    -- `deliver` carried a note saying so and that it was a rule he had not made.
    okv, why = S.canBuy(state({ ammoFull = true }))
    ok(okv == false and why == Refusal.FULL,
        'a pool already at its cap refuses the purchase', why)

    okv, why = S.canBuy(state({ ammoFull = true, balance = 0 }))
    ok(why == Refusal.FULL,
        '...and outranks the money too, because "you already have the maximum" '
            .. 'is the useful half of that answer', why)

    okv = S.canBuy(state({ ammoFull = false }))
    ok(okv == true, 'and a pool with room in it buys')
end

-- ---------------------------------------------------------------------------
describe('what one counter starts the match holding')
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-09-09: "Each shop should start the match with a random number of
-- weapons in stock, distributed across all categories they sell. Let us say
-- this number is between 3 and 8 total. They will have no limited stock on
-- ammo." / "The amount of each item they have in stock should differ between
-- shops"
--
-- THE ROLL IS DRIVEN BY AN INJECTED GENERATOR rather than by math.random, so
-- every assertion below is about the RULE and none of them is about luck. The
-- server passes BR.Rng, seeded off the clock and the match id the way
-- BR.Loot.begin is; this passes a counter, a constant, or a script.
do
    local shelf = select(1, G.build())

    -- HIS TWO NUMBERS, RETYPED FROM HIS MESSAGE. Double entry, the same
    -- technique this suite uses for the eleven anchors and the price bands:
    -- config/gunshop.lua was authored from the same sentence independently, so
    -- a transposed digit in either makes the two disagree.
    ok(G.stockMin == 3 and G.stockMax == 8,
        'the band is his: between 3 and 8 total',
        ('%s..%s'):format(tostring(G.stockMin), tostring(G.stockMax)))

    --- Every roll in [lo, hi] is answered with `pick`, clamped into range.
    local function fixed(pick)
        return function(lo, hi)
            if pick < lo then return lo end
            if pick > hi then return hi end
            return pick
        end
    end

    local function total(st)
        local n = 0
        for _, c in pairs(st) do n = n + c end
        return n
    end

    -- ═══ THE TOTAL IS ALWAYS INSIDE HIS BAND, WHATEVER THE GENERATOR SAYS ═══
    for _, p in ipairs({ 1, 3, 5, 8, 99 }) do
        local st = S.rollStock(G, shelf, fixed(p))
        local n = total(st)
        ok(n >= G.stockMin and n <= G.stockMax,
            ('a generator that always answers %d still stocks inside the band')
                :format(p), n)
    end

    -- ═══ AMMO IS NEVER COUNTED, WHICH IS THE HALF OF HIS SENTENCE A TEST CAN
    --     ACTUALLY HOLD ═══
    --
    -- "They will have no limited stock on ammo". The ABSENCE is the vocabulary:
    -- a row that is not a key here is uncounted, and BR.GunshopSolve.stockOf
    -- answers nil for it rather than zero.
    do
        local st = S.rollStock(G, shelf, fixed(1))
        local ammo = S.ofKind(shelf, BR.ItemKind.AMMO)
        ok(#ammo == 5, 'all five ammo pools are on the shelf', #ammo)
        local counted = 0
        for _, r in ipairs(ammo) do
            if st[r.id] ~= nil then counted = counted + 1 end
        end
        ok(counted == 0, 'and not one of them is stocked', counted)
        for _, r in ipairs(ammo) do
            ok(S.stockOf(st, r) == nil,
                ('%s reads as uncounted, not as empty'):format(r.id))
            break
        end

        -- AND EVERY WEAPON IS A KEY, INCLUDING THE ONES AT ZERO. A shelf that
        -- omitted its sold-out rows would be indistinguishable from a shelf
        -- that sells them without limit -- which is exactly what ammo is.
        local guns = S.ofKind(shelf, BR.ItemKind.WEAPON)
        local missing = 0
        for _, r in ipairs(guns) do
            if st[r.id] == nil then missing = missing + 1 end
        end
        ok(missing == 0,
            'every weapon row is present, at zero if it was not stocked',
            missing)
    end

    -- ═══ "DISTRIBUTED ACROSS ALL CATEGORIES THEY SELL" IS A GUARANTEE ═══
    --
    -- Spent FIRST, before a single unit goes anywhere at random: one into every
    -- rarity band on the shelf. His floor of 3 and the catalogue's three bands
    -- are the same number, which is what makes that affordable at the smallest
    -- legal roll.
    do
        local guns = S.ofKind(shelf, BR.ItemKind.WEAPON)
        local bandOf = {}
        for _, r in ipairs(guns) do bandOf[r.id] = r.rarity end

        local seen = {}
        for _, r in ipairs(guns) do seen[r.rarity] = true end
        local bands = 0
        for _ in pairs(seen) do bands = bands + 1 end
        ok(bands == 3, 'the shelf has three rarity bands', bands)

        -- AT THE SMALLEST LEGAL SHOP: three units, one per band, no slack.
        local st = S.rollStock(G, shelf, fixed(1))
        local hit = {}
        for id, n in pairs(st) do
            if n > 0 then hit[bandOf[id]] = true end
        end
        local covered = 0
        for _ in pairs(hit) do covered = covered + 1 end
        ok(covered == 3,
            'even a shop that rolled the minimum holds one of every band',
            covered)

        -- AND AT THE LARGEST. The extra units are scattered, so this is the
        -- guarantee surviving the part that is random rather than being an
        -- accident of a three-unit roll.
        st = S.rollStock(G, shelf, function(lo, hi)
            if lo == G.stockMin and hi == G.stockMax then return hi end
            return lo
        end)
        hit = {}
        for id, n in pairs(st) do
            if n > 0 then hit[bandOf[id]] = true end
        end
        covered = 0
        for _ in pairs(hit) do covered = covered + 1 end
        ok(covered == 3, '...and so does one that rolled the maximum', covered)
        ok(total(st) == G.stockMax, 'which spends all eight units', total(st))
    end

    -- ═══ SHOPS DIFFER, WHICH IS THE SECOND SENTENCE ═══
    --
    -- Rolled off ONE generator in sequence, which is exactly what the server
    -- does: eleven calls against one BR.Rng. If two consecutive shelves came out
    -- identical, either the generator is not being advanced or the roll is not
    -- reading it.
    do
        local rng = BR.Rng(20260909)
        local roll = function(lo, hi) return rng:int(lo, hi) end
        local a = S.rollStock(G, shelf, roll)
        local b = S.rollStock(G, shelf, roll)
        local same = true
        for id, n in pairs(a) do if b[id] ~= n then same = false break end end
        ok(not same, 'two counters rolled in a row do not hold the same thing')
    end

    -- ═══ A DEGENERATE CONFIG IS AN EMPTY SHOP, NEVER A CRASH ═══
    ok(next(S.rollStock(G, nil, fixed(3))) == nil,
        'no catalogue, no shelf')
    ok(next(S.rollStock({ stockMin = 0, stockMax = 0 }, shelf, fixed(0))) ~= nil,
        'a band of zero still lists every weapon row')
    do
        local st = S.rollStock({ stockMin = 0, stockMax = 0 }, shelf, fixed(0))
        ok(total(st) == 0, '...at zero', total(st))

        -- THE TWO THE WRONG WAY ROUND IS A TYPO WITH A SENSIBLE READING. The
        -- owner authors both by hand and an empty shelf nobody can explain is a
        -- worse answer than the obvious one.
        local sw = S.rollStock({ stockMin = 8, stockMax = 3 }, shelf, fixed(5))
        ok(total(sw) == 5, 'a swapped band is read the way round it was meant',
            total(sw))
    end

    -- stockOf IS THE ONE PLACE THAT DECIDES WHAT A COUNT MEANS.
    do
        local gun = S.ofKind(shelf, BR.ItemKind.WEAPON)[1]
        ok(S.stockOf({ [gun.id] = 0 }, gun) == 0, 'a zero reads as zero')
        ok(S.stockOf({}, gun) == nil, 'and a missing row reads as uncounted')
        ok(S.stockOf({ [gun.id] = -4 }, gun) == 0,
            'a negative count cannot happen and would read as empty anyway')
        ok(S.stockOf(nil, gun) == nil and S.stockOf({}, nil) == nil,
            'and nothing at all is uncounted rather than an error')
    end
end

-- ---------------------------------------------------------------------------
describe('which guns take which ammo, for the description on an ammo row')
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-09-09: "When an ammo item is in focus in the menu, a description
-- should be shown that includes a list of all weapons that ammo is used in.
-- This will help the customer understand what ammo they need to purchase for
-- their given loadout."
--
-- "ALL WEAPONS", NOT "ALL WEAPONS ON THIS SHELF". The counter sells RARE and
-- above; a player's loadout is mostly floor loot. The Pump Shotgun they are
-- carrying is COMMON, is not for sale here, and is exactly the gun they are
-- trying to work out which shells feed.
do
    local src = { BR.Config.Weapons, BR.Config.AirdropWeapons }

    local shells = S.ammoUsers(BR.AmmoType.SHELLS, src)
    local set = {}
    for _, l in ipairs(shells) do set[l] = true end

    ok(set['Pump Shotgun'] == true,
        'a COMMON-or-better gun nobody can buy here is still listed, because '
            .. 'the player is holding one')
    ok(set['Assault Shotgun'] == true,
        '...alongside the ones the counter does sell')

    -- EVERY SHELLS WEAPON AND NOTHING ELSE, checked against the shipped table
    -- from both directions -- which is the technique the whole top of this file
    -- rests on.
    local want = 0
    for _, w in ipairs(BR.Config.Weapons) do
        if w.ammo == BR.AmmoType.SHELLS then want = want + 1 end
    end
    for _, w in ipairs(BR.Config.AirdropWeapons) do
        if w.ammo == BR.AmmoType.SHELLS then want = want + 1 end
    end
    ok(#shells == want and want > 0,
        'the list is every shells weapon in the shipped tables and no other',
        ('%d of %d'):format(#shells, want))

    local wrong = {}
    for _, w in ipairs(BR.Config.Weapons) do
        if w.ammo ~= BR.AmmoType.SHELLS and set[w.label] then
            wrong[#wrong + 1] = w.label
        end
    end
    ok(#wrong == 0, 'and nothing that feeds on another pool is in it',
        table.concat(wrong, ', '))

    -- THE AIRDROP FOUR ARE HEAVY, AND THE PLAYER CAN BE HOLDING ONE. They are
    -- not for sale at any counter -- that is the rule at the top of
    -- config/gunshop.lua -- but "which ammo does my Minigun take" is the
    -- question this description exists to answer.
    local heavy = {}
    for _, l in ipairs(S.ammoUsers(BR.AmmoType.HEAVY, src)) do heavy[l] = true end
    ok(heavy['Minigun'] == true and heavy['RPG'] == true,
        'the airdrop weapons are listed under Heavy, because a player can be '
            .. 'carrying one even though no counter sells it')

    -- ORDER IS THE SOURCE TABLE'S, never pairs(). Everything in this feature
    -- that renders a list gets a stable order for free, and a description that
    -- reshuffled itself between two openings of the same menu would read as a
    -- bug.
    local a = S.ammoUsersLine(BR.AmmoType.MEDIUM, src)
    local b = S.ammoUsersLine(BR.AmmoType.MEDIUM, src)
    ok(a == b and a ~= '', 'the line is stable across calls', a)
    ok(a:find('Carbine Rifle', 1, true) ~= nil
       and a:find(', ', 1, true) ~= nil,
        '...and is the labels joined by a comma, which is a separator rather '
            .. 'than a word')

    -- NOTHING HERE INVENTS A WORD. Every entry is a `label` the owner authored.
    local made_up = 0
    for _, l in ipairs(S.ammoUsers(BR.AmmoType.LIGHT, src)) do
        local found = false
        for _, w in ipairs(BR.Config.Weapons) do
            if w.label == l then found = true break end
        end
        if not found then made_up = made_up + 1 end
    end
    ok(made_up == 0, 'and every word of it comes out of config/weapons.lua',
        made_up)

    ok(#S.ammoUsers(nil, src) == 0 and #S.ammoUsers('nonsense', src) == 0
       and #S.ammoUsers(BR.AmmoType.LIGHT, nil) == 0
       and S.ammoUsersLine(nil, nil) == '',
        'a pool nobody uses, or no tables at all, is an empty list rather '
            .. 'than an error')
end

-- ---------------------------------------------------------------------------
describe('the two sentences the counter speaks, joined where a test can see')
-- ---------------------------------------------------------------------------
--
-- ═══ HIS WORDING, RETYPED FROM HIS MESSAGE ═══
--
-- Double entry, the same technique as the anchors and the price bands. Reading
-- config/gunshop.lua here would assert that a string equals itself; typing it
-- from what he wrote means a tidied colon, a dropped full stop or an invented
-- word fails a test.
do
    local cur = BR.Config.Market.currency

    ok(cur == 'Volts', 'the currency word is the market\'s, not this file\'s', cur)

    -- "You do not have enough Volts for that item. Your balance is: {balance}
    --  Volts. remember the Volts text and quantity must be our signature color"
    local poor = S.poorToast(G, 378, cur)
    ok(poor == 'You do not have enough ~Volts~ for that item. '
            .. 'Your balance is: ~378 Volts~.',
        'the shortfall toast is exactly his sentence', poor)
    ok(select(2, poor:gsub('~', '')) == 4,
        '...with the word marked and the quantity marked, which is what "the '
            .. 'Volts text and quantity" asks for twice', poor)

    -- "You purchased {item} for {cost}."
    local shelf = select(1, G.build())
    local smg = S.rowById(shelf, S.ammoIdFor(BR.AmmoType.SMG))
    local got = S.boughtToast(G, smg, cur)
    ok(got == ('You purchased %s for ~%d Volts~.')
            :format(S.menuLabel(smg), smg.price),
        'the ammo success toast is exactly his sentence', got)
    ok(got:find('SMG Ammo x60', 1, true) ~= nil,
        '...and {item} is the row\'s own label plus the quantity it hands '
            .. 'over, which is the only thing that makes 20 Volts judgeable',
        got)

    -- A WEAPON ROW COMPOSES TOO. The scoping to ammo is the CALLER's -- he
    -- asked for this "when ammo is purchased" and gave a weapon purchase the
    -- clerk's handover instead -- and this function does not second-guess it.
    local gun = S.rowById(shelf, 'carbinerifle')
    ok(S.boughtToast(G, gun, cur) == 'You purchased Carbine Rifle for ~115 Volts~.',
        'and the same joining works for any row it is handed')

    -- A BROKEN TEMPLATE MUST NOT BE THE THING THAT THROWS. Both of these are
    -- authored strings, so a bad one is an authoring slip rather than a runtime
    -- condition -- but string.format would throw on it, on the refusal path,
    -- after a press.
    ok(S.poorToast({ poorToast = 'a', balanceToast = 'b %d' }, 5, cur) == 'a',
        'a balance template that will not take a string costs the second '
            .. 'sentence and nothing else')
    ok(S.boughtToast({ boughtToast = 'x %d %d' }, gun, cur) == '',
        '...and a broken purchase template costs the toast rather than the '
            .. 'purchase')
    ok(S.poorToast(nil, 5, cur) == '' and S.boughtToast(nil, gun, cur) == '',
        'and no config at all says nothing rather than throwing')
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

    -- ═══ THE SHIPPED NUMBERS ARE NO LONGER ZERO, AND THAT IS THE PLAYTEST ═══
    --
    -- Owner, 2026-09-09: "The ped position is consistently on top of the
    -- register (as I have validated at many shops) - let us move their position
    -- back behind the counter and to the left (the ped-s right) about 1m".
    --
    -- SO THE ASSERTION IS THAT HE IS NO LONGER ON THE ANCHOR, and specifically
    -- that he is BEHIND it and to its right. Pinned as a DIRECTION rather than
    -- as the two literals, because the two literals are exactly what he is
    -- expected to move after the next round -- but a sign flip in either one
    -- would put him in front of the counter or in the wall, which is the
    -- regression worth catching and is invisible in a diff.
    local x, y, z, h = S.clerkAt(G, st, 5.0)
    ok(z == 5.0 and h == 0.0,
        'the floor and the facing come through untouched')
    ok(y < -0.05,
        'at heading 0 the clerk stands BEHIND the register, not on it -- '
            .. 'forward is +Y and his offset is negative',
        ('%.4f'):format(y))
    ok(x > 0.05,
        "...and to the ped's right, which at heading 0 is +X -- the half of "
            .. 'his sentence this arithmetic could not express at all before',
        ('%.4f'):format(x))
    ok(math.abs(x - 1.0) < 1e-9,
        'and the lateral step is his metre', ('%.4f'):format(x))

    -- FORWARD IS (-sin h, cos h). Asserted rather than assumed, because a sign
    -- error here would put every clerk on the wrong side of every counter and
    -- would look exactly like a bad survey.
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

    -- ═══ THE LATERAL TERM, ON ITS OWN, IN BOTH FRAMES ═══
    --
    -- RIGHT IS (cos h, sin h), which is forward turned a quarter turn. Facing
    -- north, right is east. A sign error here is the same class of invisible
    -- fault as the forward one and deserves the same treatment.
    local flat = { id = 'n', x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }
    local rx, ry = S.clerkAt({ clerkRightM = 3.0 }, flat, 0.0)
    ok(math.abs(rx - 3.0) < 1e-9 and math.abs(ry) < 1e-9,
        'at heading 0 the lateral step is spent along +X, which is east',
        ('%.4f, %.4f'):format(rx, ry))

    flat.heading = 90.0
    rx, ry = S.clerkAt({ clerkRightM = 3.0 }, flat, 0.0)
    ok(math.abs(rx) < 1e-6 and math.abs(ry - 3.0) < 1e-6,
        '...and at heading 90, which faces west, right is north',
        ('%.4f, %.4f'):format(rx, ry))

    -- TURNING HIM MUST NOT MOVE HIM. `clerkFaceDeg` and the two offsets are
    -- three independent numbers and one playtest fix must not undo another --
    -- which is only true because both offsets are spent in the STORE's frame
    -- rather than the clerk's.
    flat.heading = 0.0
    local ax, ay = S.clerkAt({ clerkOffsetM = -0.7, clerkRightM = 1.0 }, flat, 0.0)
    local bx, by = S.clerkAt({ clerkOffsetM = -0.7, clerkRightM = 1.0,
                               clerkFaceDeg = 143.0 }, flat, 0.0)
    ok(math.abs(ax - bx) < 1e-9 and math.abs(ay - by) < 1e-9,
        'turning the clerk on the spot leaves him exactly where he was')
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

    -- ═══ ONE HANDOVER, TWO MACHINES, ONE NUMBER ═══
    --
    -- P2 step 4: the prop is deleted, the clerk's tasks are cleared and the
    -- player is armed "all at once" -- and the first two of those happen on the
    -- client while the third happens on the server. A literal in either file
    -- would be that moment splitting in half the day somebody tuned one side.
    ok(tonumber(G.handoverMs) ~= nil,
        'config authors how long the clerk holds the weapon out',
        tostring(G.handoverMs))
    ok(cli:find('G.handoverMs', 1, true) ~= nil,
        'the client waits config\'s number before deleting the prop')
    ok(srv:find('G.handoverMs', 1, true) ~= nil,
        '...and the server waits the SAME number before delivering, so neither '
            .. 'half can drift out of the other')
    ok(cli:find('HAND_MS = 1400', 1, true) == nil,
        'and neither half still carries a literal of its own')

    -- ═══ THE SERVER SPEAKS THREE SENTENCES NOW, AND IT AUTHORS NONE OF THEM
    --     ═══
    --
    -- It used to speak exactly one, borrowed from BR.Market.tellShortfall,
    -- because the owner had written no copy for this counter. He wrote three on
    -- 2026-09-09 and the rule did not change: every word a player reads here is
    -- authored somewhere a person can find it, and this file only joins.
    ok(srv:find('BR.Market.tellShortfall', 1, true) == nil,
        'the market\'s "You need %d more to buy that." no longer reaches this '
            .. 'counter -- the owner called it not good copy and replaced it')
    ok(srv:find('BR.GunshopSolve.poorToast', 1, true) ~= nil,
        '...with his own sentence, joined and color-marked in br_lib where a '
            .. 'test can read it rather than concatenated here')
    ok(srv:find("BR.Loot.refusalText('ammofull'", 1, true) ~= nil,
        'a full ammo pool is refused in the LOOT PICKUP\'S own words, called '
            .. 'rather than copied -- "same as we do for loot pickups"')
    ok(srv:find('Already carrying') == nil
       and srv:find('You do not have enough') == nil
       and srv:find('You purchased') == nil,
        '...and not one of those three sentences is spelled in this file')
    ok(srv:find('BR.Roster.get', 1, true) ~= nil
       and srv:find('GetPlayerPed', 1, true) == nil,
        "the position is the roster's sampled one, never a fresh GetPlayerPed "
            .. '-- which returns 0 for every player when handed a numeric src')

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE PROJECT PALETTE IS NOT IN THE SCALEFORMUI PATH, AND THIS IS THE
    -- RATCHET (owner, 2026-09-11)
    -- ═══════════════════════════════════════════════════════════════════════
    --
    --   "No ScaleformUI should ever use our cyan ever"
    --   "Same for the gold, use GTA's gold everywhere"
    --
    -- THIS BLOCK USED TO ASSERT THE EXACT OPPOSITE: that ACCENT_HEX and GOLD_HEX
    -- still equalled `--color-royale-accent` and `--color-volts` in index.css,
    -- because two retyped hexes were the only way a .gfx movie could be told our
    -- colors. The rule reversed, so the assertion reverses with it -- and it is
    -- the same two values, read out of the same document, now checked for ABSENCE.
    --
    -- ⚠ READ OUT OF index.css RATHER THAN TYPED HERE, which is what makes it
    -- survive him restyling the interface. A hex spelled in this file would guard
    -- whatever the cyan used to be on the day somebody moved it.
    local menu = readFile(ROOT .. 'br_core/client/menu.lua')
    local css  = readFile('ui-src/src/index.css')
    ok(menu ~= '', 'the theme helper exists')
    ok(css ~= '', 'and the document the palette is authored in is readable')

    --- One Lua file with its comments taken out.
    ---
    --- ⚠ THE HISTORY HAS TO STAY READABLE AND THE SWEEP HAS TO BE REAL, AND
    --- THOSE TWO PULL AGAINST EACH OTHER. client/menu.lua now explains at length
    --- that #22d3ee was the old highlight and that the parser it travelled
    --- through misreads a six-digit code as an alpha, so a search for that value
    --- over the whole file would fail on the explanation of why it is gone.
    ---
    --- DROPPING FROM `--` TO END OF LINE IS EXACT FOR THESE TWO FILES. A Lua line
    --- comment runs to the newline, and neither file puts `--` inside a string
    --- literal -- which is checked below rather than asserted here, by the fact
    --- that the stripped source still contains the code the other tests find.
    local function code(src)
        local out = {}
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do
            out[#out + 1] = line:gsub('%-%-.*$', '')
        end
        return table.concat(out, '\n')
    end

    local menuCode, cliCode = code(menu):lower(), code(cli):lower()

    -- THE HYPHENS ARE ESCAPED. `-` is Lua's lazy quantifier, so a raw
    -- `--color-volts` is not the string it looks like -- it is a pattern that
    -- matches almost nothing, and an assertion built on it would pass for the
    -- wrong reason.
    local brand = {}
    for _, name in ipairs({ 'royale%-accent', 'volts' }) do
        local hex = css:lower():match('%-%-color%-' .. name .. ':%s*#(%x%x%x%x%x%x)')
        if hex then brand[#brand + 1] = hex end
    end
    ok(#brand == 2,
        'both brand colors are still authored in index.css, so the sweep below '
            .. 'is checking against something real rather than against nothing',
        table.concat(brand, ', '))

    local leaked = {}
    for _, hex in ipairs(brand) do
        if menuCode:find(hex, 1, true) then
            leaked[#leaked + 1] = 'client/menu.lua names #' .. hex
        end
        if cliCode:find(hex, 1, true) then
            leaked[#leaked + 1] = 'client/gunshop.lua names #' .. hex
        end
    end
    ok(#leaked == 0,
        'and neither the cyan nor the gold is anywhere in the code of either '
            .. 'file -- the rule is total rather than the two rows he pointed at',
        #leaked > 0 and table.concat(leaked, '; ') or nil)

    -- AND NO HEX AT ALL, WHICH IS STRONGER AND IS ONLY STATEABLE NOW. Every
    -- color on this surface is a HUD PALETTE INDEX, so a hex literal in the path
    -- is somebody starting over rather than somebody tuning. It also retires
    -- SColor.FromHex's eight-digit trap by making the parser unreachable.
    ok(menuCode:find('#%x%x%x') == nil,
        'client/menu.lua names no hex color at all any more',
        menuCode:match('#%x%x%x%x*'))
    ok(cliCode:find('#%x%x%x') == nil,
        'and neither does the shop file',
        cliCode:match('#%x%x%x%x*'))

    -- ═══ AND THE REPLACEMENTS ARE NAMED, SO THE SWEEP IS NOT JUST A DELETION
    --     ═══
    --
    -- ⚠ EVERY ONE OF THESE READS THE STRIPPED, LOWERCASED SOURCE, and the two
    -- absences are the reason it has to. client/menu.lua now explains in prose
    -- that BR.Menu.accent is gone and that SetBannerColor used to paint the cyan,
    -- so an assertion over the raw file would find both names in the paragraph
    -- saying they are not called -- and fail for exactly the wrong reason. That
    -- is not hypothetical: it is what happened on the first run of this block.
    ok(menuCode:find('scolor.fromhudcolor', 1, true) ~= nil,
        "the colors come through the library's own HUD-palette constructor, "
            .. 'which is what SColor.HUD_White and its ninety siblings are built '
            .. 'with')
    ok(menuCode:find('br.menu.accent', 1, true) == nil
       and cliCode:find('br.menu.accent', 1, true) == nil,
        'BR.Menu.accent is GONE rather than merely unused, so no later menu can '
            .. 'reach the cyan by calling the function that used to hand it out')
    ok(menuCode:find('function br.menu.gold() return hudcolor(price_hud) end',
                     1, true) ~= nil,
        'the Volts counter reads the same index the price token names, so the '
            .. 'two golds on one strip cannot drift apart -- that is the site '
            .. 'his gold ruling newly reached')
    ok(menuCode:find('setbannercolor', 1, true) == nil,
        'and no banner color is set at all -- it was the cyan on the no-sprite '
            .. "branch, and the library's own default is SColor.HUD_None")
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
    -- THE DEV DUMP AND THE CLOCK. Both are natives the file now touches:
    -- `brgunshopstock` prints what a match stocked, and GetGameTimer is half the
    -- stock seed. Neither is under test here; they are stubbed so that loading
    -- the file headless is possible at all.
    local commands = {}
    function RegisterCommand(name, fn) commands[name] = fn end
    function GetGameTimer() return 1234567 end

    -- ═══ THE HANDOVER PAUSE, HELD OPEN THE WAY THE CHARGE IS ═══
    --
    -- P2 step 4 puts the delivery at the END of the clerk's presentation, so
    -- the server schedules it. A stub that ran the callback immediately would
    -- make the ordering untestable -- which is the whole assertion -- so these
    -- queue like BR.Market.hold does and `runTimers()` is what lets them go.
    local timers = {}
    function SetTimeout(ms, fn)
        timers[#timers + 1] = { ms = ms, fn = fn }
    end
    local function runTimers()
        local due = timers
        timers = {}
        for _, t in ipairs(due) do t.fn() end
        return #due
    end

    BR.Server = {
        matchOf = function(src)
            local e = roster[src]
            return e and matches[e.matchId] or nil
        end,
        eachMatch = function(fn)
            local ids = {}
            for id in pairs(matches) do ids[#ids + 1] = id end
            table.sort(ids)
            for _, id in ipairs(ids) do fn(matches[id]) end
        end,
        --- EVERYONE IN ONE MATCH, sorted, exactly as server/main.lua's is. The
        --- shelf is shared, so this is who hears a purchase.
        audience = function(m)
            local out = {}
            for src, e in pairs(roster) do
                if e.matchId == m.id then out[#out + 1] = src end
            end
            table.sort(out)
            return out
        end,
        notify = function(target, text, tone)
            notices[#notices + 1] =
                { src = target, text = text, tone = tone }
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

    --- Let the held DynamoDB writes land -- AND the handover that follows them.
    --- The presentation pause is scheduled inside the charge callback, so a
    --- settle that stopped there would leave every weapon undelivered.
    local function settleCharges()
        local due = BR.Market.held
        BR.Market.held = {}
        for _, fn in ipairs(due) do fn() end
        runTimers()
    end

    local bagFull = false
    --- THE AMMO POOLS ARE REAL HERE, because the counter now READS them: a
    --- purchase is refused when the pool this bundle fills is already at
    --- BR.Config.AmmoCaps. A stub that had no pools would exercise the
    --- defensive branch and never the rule.
    local pools = {}
    BR.Inv = {
        of = function(src)
            if not pools[src] then pools[src] = { ammo = {} } end
            return pools[src]
        end,
        give = function(src, stack, opts)
            given[#given + 1] = { src = src, stack = stack, opts = opts }
            if bagFull then return false, nil, 'carrymax' end
            return true, nil, nil
        end,
    }
    --- THE LOOT PICKUP'S OWN REFUSAL SENTENCE, which the counter borrows rather
    --- than copies -- owner, 2026-09-09: "same as we do for loot pickups". The
    --- WORDING is server/loot.lua's and is under test in tools/test_loot.lua;
    --- what this suite pins is that the counter CALLS it.
    BR.Loot = {
        dropForPlayer = function(src, stack)
            dropped[#dropped + 1] = { src = src, stack = stack }
        end,
        refusalText = function(reason)
            return 'REFUSAL:' .. tostring(reason)
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
        pools = {}
        -- THE SHELVES ARE KEYED BY MATCH ID AND NOTHING ELSE WOULD CLEAR THEM
        -- BETWEEN CASES. This is the real hook the server file installs, called
        -- for the same reason server/players.lua calls it: a match that is gone
        -- has no shelves. Using it here also means the hook itself is exercised
        -- by every case in this block rather than by one.
        if handlers['br:match:destroyed'] then
            handlers['br:match:destroyed']({ matchId = 1 })
        end
    end

    --- EVERY SHELF IN MATCH 1, SET TO ONE NUMBER.
    ---
    --- ═══ WHY THE OTHER TESTS IN THIS BLOCK NEED THIS ═══
    ---
    --- A counter now holds between three and eight weapons for the whole match,
    --- so "buy a Heavy Sniper" is a question about the shelf as well as about
    --- the money. Every test below that is NOT about stock tops the shelves up
    --- first, so that a roll which happened not to put a Heavy Sniper in Pillbox
    --- Hill cannot fail an assertion about dying inside a DynamoDB write.
    --- The stock rules are tested in their own block, on their own numbers.
    --- @param n integer
    local function stockAll(n)
        local by = BR.Gunshop.stock(1, matches[1])
        if not by then return end
        for _, one in pairs(by) do
            for id in pairs(one) do one[id] = n end
        end
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
        if opts.stock ~= false then quiet(stockAll, 99) end
        if opts.ammo then
            local inv = BR.Inv.of(src)
            for pool, n in pairs(opts.ammo) do inv.ammo[pool] = n end
        end
    end

    --- One purchase, played all the way through.
    ---
    --- THE TIMERS ARE DRAINED, because since P2 step 4 a weapon is delivered at
    --- the END of the clerk's presentation rather than at the charge. Every
    --- assertion below about what a buyer ends up holding is an assertion about
    --- the whole event, so the default is the whole event. `opts.hold` is for
    --- the one test that needs to look inside it -- see 'P2 step 4'.
    local function buy(src, id, extra, opts)
        local payload = { id = id }
        if extra then for k, v in pairs(extra) do payload[k] = v end end
        _G.source = src
        quiet(handlers[BR.Net.GUNSHOP_BUY], payload)
        if not (type(opts) == 'table' and opts.hold == true) then
            quiet(runTimers)
        end
    end

    local function boughtFor(src)
        for _, s in ipairs(sent) do
            if s.name == BR.Net.GUNSHOP_BOUGHT and s.src == src then
                return s.payload
            end
        end
        return nil
    end

    --- The refusal toast one player was sent, payload and all.
    ---
    --- IT IS A RAW NOTIFY RATHER THAN BR.Server.notify, and that is the thing
    --- worth reading here: the `shop.denied` cue has to ride ON the payload so
    --- it REPLACES br_ui's general warn sound rather than playing on top of it.
    --- server/market.lua's own `refuse` carries the same three fields for the
    --- same reason.
    local function noticeFor(src)
        for _, s in ipairs(sent) do
            if s.name == BR.Net.NOTIFY and s.src == src then return s.payload end
        end
        return nil
    end

    --- What the stock table for match 1 says one counter holds.
    local function shelfAt(storeId)
        local by = BR.Gunshop.stock(1, matches[1])
        return by and by[storeId] or nil
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
    -- I3, and the half this file can prove. Owner, 2026-09-09: "when they buy a
    -- weapon and it's granted to them, the weapon must immediately be the
    -- inventory slot in focus." BR.Inv.give will not arm a player who is
    -- already holding something -- correctly, for floor loot -- so the shop has
    -- to say that a purchase is not floor loot. What give() then DOES with the
    -- flag is asserted against the real inventory in tools/test_roster.lua.
    ok(#given == 1 and given[1].opts and given[1].opts.focus == true,
        '...and with `focus`, because a gun they chose and paid for goes into '
            .. 'their hands rather than into a slot they cannot see (I3)')
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
    describe('P2 step 4: the arming is the END of the handover, not the start')
    -- -----------------------------------------------------------------------
    do
        -- ═══ HIS SEQUENCE, AND IT WAS RUNNING BACKWARDS ═══
        --
        --   3. the weapon I just purchased is spawned as a network entity in
        --      the clerk's hands as the clerk presents it to me
        --   4. the entity is deleted, the ped tasks cleared, and I am now armed
        --      with that weapon ALL AT ONCE
        --
        -- server/gunshop.lua called deliver() and THEN fired GUNSHOP_BOUGHT, so
        -- the gun was in the bag -- and since I3 in the player's hands -- before
        -- the clerk had begun to offer it. The clerk was animated presenting
        -- something the buyer was already holding.
        reset()
        player(60)
        buy(60, 'carbinerifle', nil, { hold = true })

        ok(boughtFor(60) ~= nil and boughtFor(60).row == 'carbinerifle',
            'the client is told to start the presentation')
        ok(#charged == 1, '...and the Volts are already gone, because the '
            .. 'charge is still the point of no return', #charged)
        ok(#given == 0,
            'but the weapon is NOT in the bag yet -- the clerk is still holding '
                .. 'it out (P2 step 4)', #given)

        local fired = 0
        quiet(function() fired = runTimers() end)
        ok(fired == 1, 'exactly one handover is scheduled', fired)
        ok(#given == 1 and given[1].stack.item == 'carbinerifle',
            'and when the presentation ends the gun lands',
            #given)
        ok(#given == 1 and given[1].opts and given[1].opts.focus == true,
            '...into their hands, which is the same moment (I3 + P2 step 4)')

        -- ═══ AMMO NEVER WAITS, BECAUSE THERE IS NOTHING TO WAIT FOR ═══
        --
        -- P2 step 5: "This animation/entity/speech process should be skipped for
        -- all ammo purchases." No presentation means no pause; scheduling one
        -- would be a second and a half of nothing before a number moved.
        reset()
        player(61)
        buy(61, 'ammo_' .. BR.AmmoType.SMG, nil, { hold = true })
        ok(#given == 1 and given[1].stack.kind == BR.ItemKind.AMMO,
            'an ammo purchase is delivered before any timer runs')
        ok(runTimers() == 0, '...and schedules no handover at all')
        ok(#notices >= 1, 'and it still gets his success toast', #notices)

        -- ═══ THE FORFEIT GATE IS ASKED AGAIN AT THE FAR END ═══
        --
        -- The wait is a window a player can die in like any other, and the file
        -- already has a rule for a buyer who stopped being alive between the
        -- charge and the goods. It is the same rule, so it is the same answer:
        -- no item, no refund, and the unit goes back on the shelf because
        -- nothing was handed over.
        reset()
        player(62)
        local before = BR.Gunshop.stock(1, matches[1])['pillbox']['carbinerifle']
        buy(62, 'carbinerifle', nil, { hold = true })
        -- `OUT`, NOT `DEAD`. The enum's KEY is OUT and its wire value is 'dead'
        -- (see br_lib/shared/enums.lua) -- and BR.PlayerState.DEAD being nil
        -- would have made this case pass for the wrong reason, because `~= nil`
        -- is true for a live player too. tools/verify.sh's enum gate caught it.
        roster[62].state = BR.PlayerState.OUT
        quiet(runTimers)
        ok(#given == 0, 'a buyer who died during the handover gets nothing',
            #given)
        ok(#charged == 1, '...and is not refunded, which the file says twice')
        local after = BR.Gunshop.stock(1, matches[1])['pillbox']['carbinerifle']
        ok(after == before,
            'but the rifle goes back on the shelf, because nobody received it',
            ('%s -> %s'):format(tostring(before), tostring(after)))
    end

    -- -----------------------------------------------------------------------
    describe('a player cannot buy what they cannot afford')
    -- -----------------------------------------------------------------------
    reset()
    player(20, { balance = 114 })
    buy(20, 'carbinerifle')
    ok(#charged == 0 and #given == 0, 'one Volt short buys nothing')

    -- ═══ HIS SENTENCE, CHARACTER FOR CHARACTER ═══
    --
    -- Owner, 2026-09-09: "give them a toast that says You do not have enough
    -- Volts for that item. Your balance is: {balance} Volts. remember the Volts
    -- text and quantity must be our signature color."
    --
    -- RETYPED FROM HIS MESSAGE RATHER THAN READ OUT OF THE CONFIG, which is the
    -- double-entry this suite already uses for the eleven anchors and the price
    -- bands. Reading config/gunshop.lua here would assert that the string equals
    -- itself; typing it from his message means a "helpful" tidy of the colon, a
    -- dropped full stop or an invented word fails a test.
    local sh = noticeFor(20)
    ok(sh ~= nil and sh.text ==
        'You do not have enough ~Volts~ for that item. '
            .. 'Your balance is: ~114 Volts~.',
        'it says exactly what he wrote, with his balance in it',
        sh and sh.text)
    ok(sh ~= nil and sh.tone == 'warn' and sh.cue == 'shop.denied',
        '...and carries the refusal cue ON the payload, so one sound plays '
            .. 'rather than the general warn sound and a second one')
    ok(sh ~= nil and select(2, sh.text:gsub('~', '')) == 4,
        'both the word and the figure are marked for the signature color -- '
            .. 'two pairs of tildes, which is what he asked for twice')
    ok(sh ~= nil and sh.text:find('378', 1, true) == nil
       and sh.text:find('more to buy', 1, true) == nil,
        'and the sentence he called not good copy is gone from this counter')

    reset()
    player(21, { balance = 115 })
    buy(21, 'carbinerifle')
    ok(#charged == 1 and #given == 1,
        'spending your last Volt at the counter is a purchase, not an '
            .. 'overdraft')
    ok(noticeFor(21) == nil, 'and says nothing')

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

    -- -----------------------------------------------------------------------
    describe('the shelf empties, and empties for everybody')
    -- -----------------------------------------------------------------------
    --
    -- Owner, 2026-09-09: "Each shop should start the match with a random number
    -- of weapons in stock ... between 3 and 8 total" / "If an item is out of
    -- stock, the row should be locked and a price should not be shown".
    reset()
    player(70)
    quiet(stockAll, 2)
    local before = shelfAt('pillbox').carbinerifle
    buy(70, 'carbinerifle')
    ok(#charged == 1 and shelfAt('pillbox').carbinerifle == before - 1,
        'a purchase takes one off that counter', shelfAt('pillbox').carbinerifle)

    buy(70, 'carbinerifle')
    ok(#charged == 2 and shelfAt('pillbox').carbinerifle == 0,
        'and the second takes the last one')

    buy(70, 'carbinerifle')
    ok(#charged == 2 and #given == 2,
        'the third press buys nothing, because there is nothing there')
    ok(noticeFor(70) == nil,
        '...in silence, because he asked for the row to be LOCKED with no '
            .. 'price rather than for a sentence, and inventing one is the '
            .. 'slop his standing rule refuses')

    -- ═══ THE SHELF IS PER COUNTER, WHICH IS THE OTHER HALF OF S2 ═══
    ok(shelfAt('pillbox').carbinerifle == 0
       and shelfAt('cypress').carbinerifle == 2,
        'emptying Pillbox Hill does not empty the counter across town')

    -- ═══ AMMO IS NEVER COUNTED, HOWEVER MANY TIMES IT IS BOUGHT ═══
    reset()
    player(71)
    for _ = 1, 12 do buy(71, 'ammo_smg') end
    ok(#charged == 12 and #given == 12,
        'twelve boxes of SMG ammo is twelve purchases -- "no limited stock on '
            .. 'ammo"')
    ok(shelfAt('pillbox').ammo_smg == nil,
        'and no ammo row is a key on any shelf at all')

    -- -----------------------------------------------------------------------
    describe('the unit comes off the shelf BEFORE the money moves')
    -- -----------------------------------------------------------------------
    --
    -- A charge is a DynamoDB round trip of up to six seconds and the shelf is
    -- shared. Decrementing after the callback would let two players pressing on
    -- the last Carbine inside one round trip both read a stock of 1, both pass
    -- the predicate, and both get a gun that only existed once.
    reset()
    player(72)
    player(73)
    quiet(stockAll, 1)
    BR.Market.hold = true
    buy(72, 'carbinerifle')
    ok(shelfAt('pillbox').carbinerifle == 0,
        'the shelf is short the moment the charge is issued, not when it lands')
    buy(73, 'carbinerifle')
    quiet(settleCharges)
    ok(#charged == 1 and #given == 1,
        'so the second player inside the round trip is refused rather than '
            .. 'being sold the same gun')

    -- ...AND IT GOES BACK IF NOTHING IS HANDED OVER.
    reset()
    player(74, { balance = 0 })
    quiet(stockAll, 1)
    -- A charge that reaches the ledger and is refused there, rather than one
    -- refused by canBuy: the reservation has already happened by then.
    BR.Market.balances[74] = 5000
    BR.Market.hold = true
    buy(74, 'carbinerifle')
    ok(shelfAt('pillbox').carbinerifle == 0, 'reserved while in flight')
    BR.Market.balances[74] = 0
    quiet(settleCharges)
    ok(#charged == 0 and #given == 0, 'the charge is refused at the ledger')
    ok(shelfAt('pillbox').carbinerifle == 1,
        '...and the gun goes back on the shelf, because nobody was handed one')

    -- THE FORFEIT PATH TOO. It still costs that player the Volts -- there is no
    -- refund path anywhere in this feature -- but the gun was never handed to
    -- anybody, so a shelf that stayed short would be wrong about the world.
    reset()
    player(75)
    quiet(stockAll, 1)
    BR.Market.hold = true
    buy(75, 'heavysniper')
    roster[75].state = BR.PlayerState.OUT
    quiet(settleCharges)
    ok(#charged == 1 and #given == 0, 'the debit lands and the item does not')
    ok(shelfAt('pillbox').heavysniper == 1,
        '...and the shelf is whole again, because nothing left it')

    -- -----------------------------------------------------------------------
    describe('every client in the match is told what is left')
    -- -----------------------------------------------------------------------
    --
    -- The shelf is SHARED, so the player who takes the last Carbine takes it
    -- from everybody in that match. A client that only heard about its own
    -- purchases would show a row as available that nobody can buy.
    reset()
    player(80)
    player(81)
    quiet(BR.Gunshop.sync)

    local fulls, deltas = 0, 0
    for _, s in ipairs(sent) do
        if s.name == BR.Net.GUNSHOP_STOCK then
            if s.payload.full == true then fulls = fulls + 1
            else deltas = deltas + 1 end
        end
    end
    ok(fulls == 2 and deltas == 0,
        'both players are sent the whole picture once', fulls)

    -- ...AND ONLY ONCE. `told` is what stops a second of heartbeat becoming a
    -- second copy of eleven shelves on the wire.
    quiet(BR.Gunshop.sync)
    quiet(BR.Gunshop.sync)
    fulls = 0
    for _, s in ipairs(sent) do
        if s.name == BR.Net.GUNSHOP_STOCK and s.payload.full == true then
            fulls = fulls + 1
        end
    end
    ok(fulls == 2, 'and not again on every tick', fulls)

    sent = {}
    quiet(stockAll, 3)
    buy(80, 'carbinerifle')
    local heard = {}
    for _, s in ipairs(sent) do
        if s.name == BR.Net.GUNSHOP_STOCK then
            heard[s.src] = s.payload
        end
    end
    ok(heard[80] ~= nil and heard[81] ~= nil,
        "one player's purchase reaches the other player's client")
    ok(heard[81] ~= nil and heard[81].full ~= true
       and heard[81].stores.pillbox.carbinerifle == 2,
        '...as a delta naming the counter, the row and what is left of it',
        heard[81] and heard[81].stores.pillbox.carbinerifle)

    -- A MATCH THAT IS GONE HAS NO SHELVES, and nothing else would ever clear
    -- this table -- it is keyed by match id and matches are minted forever.
    handlers['br:match:destroyed']({ matchId = 1 })
    ok(BR.Gunshop.stock(1) == nil, 'a destroyed match takes its shelves with it')

    -- -----------------------------------------------------------------------
    describe('an ammo pool that is already full')
    -- -----------------------------------------------------------------------
    --
    -- Owner, 2026-09-09: "If someone is already carrying the max of an ammo, it
    -- should be locked out in the menu. If they still try to purchase it,
    -- reject the purchase and give them a toast explaining they already have
    -- the max (same as we do for loot pickups)".
    reset()
    player(90, { ammo = { [BR.AmmoType.SMG] = BR.Config.AmmoCaps[BR.AmmoType.SMG] } })
    buy(90, 'ammo_smg')
    ok(#charged == 0 and #given == 0,
        'a pool at its cap takes no money and hands over nothing -- it used to '
            .. 'take the Volts and leave the bundle on the floor')
    ok(#notices == 1 and notices[1].src == 90
       and notices[1].text == 'REFUSAL:ammofull'
       and notices[1].tone == 'warn',
        "...and says so in the LOOT PICKUP'S own sentence, called rather than "
            .. 'copied, so the day he rewords one both move',
        notices[1] and notices[1].text)

    -- ONE ROUND SHORT OF THE CAP STILL BUYS. The bundle clamps and the
    -- remainder drops, exactly as a piece of ammo off the floor does; the
    -- refusal is for a pool that is FULL, which is what he wrote.
    reset()
    player(91, { ammo = { [BR.AmmoType.SMG] = BR.Config.AmmoCaps[BR.AmmoType.SMG] - 1 } })
    buy(91, 'ammo_smg')
    ok(#charged == 1 and #given == 1, 'one round short of the cap is a sale')

    -- AND A WEAPON IS NEVER REFUSED FOR THIS, whatever the pools hold.
    reset()
    player(92, { ammo = { [BR.AmmoType.MEDIUM] = BR.Config.AmmoCaps[BR.AmmoType.MEDIUM] } })
    buy(92, 'carbinerifle')
    ok(#charged == 1, 'a full Medium pool does not stop you buying a rifle')

    -- -----------------------------------------------------------------------
    describe('the ammo purchase says something, and the weapon purchase does not')
    -- -----------------------------------------------------------------------
    --
    -- Owner, 2026-09-09: "when ammo is purchased show a success toast: You
    -- purchased {item} for {cost}. otherwise they have no way to know anything
    -- went through."
    reset()
    player(95)
    buy(95, 'ammo_smg')
    ok(#notices == 1 and notices[1].src == 95
       and notices[1].text == 'You purchased SMG Ammo x60 for ~20 Volts~.'
       and notices[1].tone == 'success',
        'buying ammo says exactly what he wrote, with the figure marked for '
            .. 'the signature color',
        notices[1] and notices[1].text)

    reset()
    player(96)
    buy(96, 'carbinerifle')
    ok(#notices == 0,
        'and buying a WEAPON says nothing, because the clerk hands it over -- '
            .. 'which is his scoping rather than an omission')
end


-- ---------------------------------------------------------------------------
-- The counter's CHROME, stood up for real
-- ---------------------------------------------------------------------------
--
-- ═══ WHY THIS IS A SANDBOX AND NOT ANOTHER GREP ═══
--
-- The block above checks client/gunshop.lua by reading its source, which is the
-- pattern this project uses for client files because they register loop bands
-- and keypress listeners at load. That pattern met its limit on 2026-09-09: the
-- owner playtested the counter and filed eleven separate reports about what the
-- menu LOOKED LIKE, and every one of them is a fact about ROWS -- their order,
-- their labels, their locks, their icons -- that a presence check on an
-- identifier cannot see. A grep for `LeftBadge` is equally true whether the
-- badge is a padlock or a gun and whether it is on the right row.
--
-- So client/menu.lua and client/gunshop.lua are both LOADED here against a stub
-- of the vendored library, and the menu is opened the way a player opens it:
-- resource start, walk into range, let the reconciler build a clerk, press the
-- interact key. The assertions are then about the items that came out.
--
-- WHAT THE STUB IS AND IS NOT. It is an honest model of the ScaleformUI entry
-- points this project calls -- New, AddItem, RightLabel, LeftBadge, Enabled,
-- Description -- and it is NOT a model of the movie. Nothing here can tell you
-- what the banner looks like, whether GTA's HUD_COLOUR_GOLD reads as our gold,
-- or whether a ped voices a speech line. Those are playtest questions and they
-- are named as such in the handover rather than faked here.
do
    -- ═══ THE VENDORED LIBRARY, MODELLED ═══
    local lastMenu = nil

    UIMenu = {}
    UIMenu.__index = UIMenu
    function UIMenu.New(title, subTitle, x, y, glare, txd, txn)
        lastMenu = setmetatable({
            Title = title, SubTitle = subTitle,
            TxtDictionary = txd or '', TxtName = txn or '',
            Items = {},
            -- THE TWO DEFAULTS THE OWNER REPORTED. The real library ships a
            -- cursor on and two instructional buttons in the list, so this stub
            -- ships the same two: turning them off is then something a test can
            -- watch happen rather than assume.
            InstructionalButtons = { 'select', 'back' },
            _mouse = true, _edge = true, _visible = false,
            -- DEFAULTED TO A NO-OP AT CONSTRUCTION, exactly as the real
            -- UIMenu.New does. It is the seam a consumer overrides to hear
            -- about a close it did not ask for.
            OnMenuClose = function() end,
        }, UIMenu)
        return lastMenu
    end
    function UIMenu:MouseControlsEnabled(v)
        if v ~= nil then self._mouse = v end
        return self._mouse
    end
    function UIMenu:MouseEdgeEnabled(v)
        if v ~= nil then self._edge = v end
        return self._edge
    end
    function UIMenu:SetBannerColor(c) self._bannerColor = c end
    function UIMenu:SetBannerSprite(d, n)
        self.TxtDictionary = d
        self.TxtName = n
    end
    function UIMenu:CounterColor(c) self._counter = c end
    function UIMenu:SubtitleColor(n) self._subtitle = n end
    function UIMenu:AddItem(i)
        self.Items[#self.Items + 1] = i
        i.ParentMenu = self
    end
    function UIMenu:Visible(v)
        if v ~= nil then
            local was = self._visible
            self._visible = v
            -- ON THE FALLING EDGE, FROM INSIDE Visible ITSELF, which is where
            -- the real library calls it (ScaleformUI.lua, UIMenu:Visible, the
            -- `else` arm). That placement is the whole reason this is a usable
            -- seam: EVERY path that lowers the menu goes through Visible, so a
            -- consumer that hooks it hears about the ones it did not initiate.
            if was == true and v == false
                and type(self.OnMenuClose) == 'function' then
                self.OnMenuClose(self)
            end
        end
        return self._visible
    end

    --- THE BACK BUTTON, AND IT TELLS US NOTHING DIRECTLY.
    ---
    --- UIMenu:GoBack at breadcrumb depth 1 calls
    --- MenuHandler:CloseAndClearHistory, which lowers the menu with
    --- Visible(false) and does not touch any state a consumer owns. Modelling
    --- it is what makes "the player pressed Back" a thing this suite can do --
    --- without it, the only close the suite could ever produce was our own.
    function UIMenu:GoBack()
        if self._visible then self:Visible(false) end
    end

    UIMenuItem = {}
    UIMenuItem.__index = UIMenuItem
    -- ═══ THE TWO FALLBACKS ARE MODELLED, AND THAT IS THE WHOLE POINT OF THEM
    --     ═══
    --
    -- The real constructor is `color or SColor.HUD_Panel_light` and
    -- `highlightColor or SColor.HUD_White`. Since 2026-09-11 the gun shop PASSES
    -- NOTHING for the highlight and nothing for three of the four separators, so
    -- "what the library defaults to" stopped being trivia and became the shipped
    -- appearance. A stub that stored a nil would make every assertion about the
    -- selected row vacuous.
    function UIMenuItem.New(text, description, main, highlight)
        return setmetatable({
            _text = text, _Description = description,
            _main = main or SColor.HUD_Panel_light,
            _highlight = highlight or SColor.HUD_White,
            _Enabled = true, ItemId = 0,
        }, UIMenuItem)
    end
    function UIMenuItem:RightLabel(t)
        if t ~= nil then self._rightLabel = tostring(t) end
        return self._rightLabel
    end
    function UIMenuItem:LeftBadge(b)
        if tonumber(b) then self._leftBadge = tonumber(b) end
        return self._leftBadge
    end

    -- ═══ MODELLED THE WAY THE LIBRARY REALLY BEHAVES, INCLUDING THE PART THAT
    --     IS A TRAP ═══
    --
    -- ScaleformUI keeps a badge TWICE on every item -- `_leftBadge`, an integer,
    -- and `customLeftIcon`, a { TXD, TXN } pair -- and pushes BOTH into the movie
    -- on every redraw. CustomLeftBadge writes the pair and sets `_leftBadge` to
    -- -1 (BadgeStyle.CUSTOM); LeftBadge above writes the integer and LEAVES THE
    -- PAIR WHERE IT WAS.
    --
    -- A STUB THAT CLEARED THE PAIR WOULD HIDE THE ONE BUG WORTH CATCHING. The
    -- gun shop flips rows between an icon and a padlock on every balance change,
    -- so a row that wore a weapon icon and then became unaffordable would push a
    -- padlock id alongside a stale texture name. Reproducing the library's own
    -- non-clearing behavior is what makes BR.Menu.leftBadge's ordering testable.
    function UIMenuItem:CustomLeftBadge(txd, txn)
        self._leftBadge = -1
        self.customLeftIcon = { TXD = txd, TXN = txn }
    end
    function UIMenuItem:Enabled(b)
        if b ~= nil then self._Enabled = b end
        return self._Enabled
    end
    function UIMenuItem:Description(s)
        if s ~= nil then self._Description = tostring(s) end
        return self._Description
    end
    -- A SETTER ONLY WHEN IT IS HANDED SOMETHING, which is how the library reads
    -- it: `UIMenuItem:MainColor(color)` with no argument RETURNS the current
    -- colour and changes nothing. Modelling that matters for the shading, where
    -- the row is repainted on every refresh: a stub that assigned nil would make
    -- "the shade came off" pass on a build where neither arm produced a colour,
    -- and a stub that ignored nil would hide a shade that never came off.
    function UIMenuItem:MainColor(c)
        if c ~= nil then self._main = c end
        return self._main
    end

    -- ItemId 6 AND A Jumpable FLAG are the two things that make a separator a
    -- separator rather than a row somebody disabled. The real GoUp and GoDown
    -- skip on exactly that pair.
    UIMenuSeparatorItem = {}
    UIMenuSeparatorItem.__index = UIMenuSeparatorItem
    setmetatable(UIMenuSeparatorItem, { __index = UIMenuItem })
    function UIMenuSeparatorItem.New(text, jumpable)
        local b = UIMenuItem.New(text, '', nil, nil)
        b.Jumpable = jumpable
        b.ItemId = 6
        return setmetatable(b, UIMenuSeparatorItem)
    end

    MenuHandler = {}
    BadgeStyle = { CUSTOM = -1, NONE = 0, LOCK = 1, AMMO = 13, GUN = 20 }

    SColor = {}
    -- THE EIGHT-DIGIT RULE, MODELLED THE WAY THE LIBRARY MODELS IT: an assert on
    -- the `#` and nothing else.
    --
    -- ⚠ KEPT THOUGH NOTHING CALLS IT ANY MORE. Owner, 2026-09-11: "No ScaleformUI
    -- should ever use our cyan ever", and "Same for the gold" -- so client/menu.lua
    -- holds no hex at all and this parser is unreachable from our code. It stays
    -- modelled so that the day somebody adds a hex back, the suite is standing
    -- where the trap is rather than having to be rebuilt first.
    function SColor.FromHex(h)
        assert(type(h) == 'string' and h:sub(1, 1) == '#', 'not a hex')
        return { hex = h }
    end
    function SColor.FromArgb(a, r, g, b) return { a = a, r = r, g = g, b = b } end

    -- ═══ THE HUD PALETTE, WHICH IS NOW WHERE EVERY COLOR ON THIS SURFACE COMES
    --     FROM ═══
    --
    -- GetHudColour(n) answers the r, g, b, a the engine holds for index n, out of
    -- common:/data/ui/hudcolor.dat. SColor.FromHudColor is the library's own
    -- wrapper and is how it builds its ninety-odd named colors at load.
    --
    -- ⚠ THE RGB THIS STUB ANSWERS IS NOT THE REAL RGB AND IS NOT MEANT TO BE.
    -- hudcolor.dat is not in this repository, and a test that hard-coded
    -- "index 9 is 93,182,229" would be asserting a fact about a file it cannot
    -- read. What the assertions below check is WHICH INDEX was asked for, so the
    -- answer only has to be distinguishable per index -- and `hud` carries the
    -- index so they can say so directly.
    local hudAsked = {}
    function GetHudColour(n)
        hudAsked[#hudAsked + 1] = n
        return n, n, n, 255
    end
    function SColor.FromHudColor(n)
        assert(n ~= nil, 'Invalid HUD color value')
        local r, g, b, a = GetHudColour(n)
        return { hud = n, a = a, r = r, g = g, b = b }
    end
    -- THE TWO DEFAULTS THE LIBRARY FALLS BACK TO, AND BOTH ARE GTA INDICES.
    -- UIMenuItem.New uses `color or SColor.HUD_Panel_light` and
    -- `highlightColor or SColor.HUD_White`, which the bundle defines as
    -- FromHudColor(152) and FromHudColor(1). That is what makes "pass nothing"
    -- a real answer to "use GTA's palette" rather than an absence.
    SColor.HUD_White = SColor.FromHudColor(1)
    SColor.HUD_Panel_light = SColor.FromHudColor(152)

    assert(loadfile(ROOT .. 'br_core/client/menu.lua'))()

    -- ═══ THE HOST, MODELLED ═══
    local loops, keys, handlers, cmds = {}, {}, {}, {}
    local dui, sfx, sent, speech, drawn = {}, {}, {}, {}, {}
    local peds, nextPed = {}, 100
    local me = { x = 0.0, y = 0.0, z = 0.0 }
    local invAmmo = {}

    BR.Loop = {
        SLOW = 'slow', TICK = 'tick', FRAME = 'frame',
        register = function(_, name, fn) loops[name] = fn end,
    }
    BR.Keys = { on = function(k, fn) keys[k] = fn end, uiScreen = nil }
    BR.Dui = {
        page = function() return { w = 512, h = 256 } end,
        send = function(_, d) dui[#dui + 1] = d end,
        drawFace = function(_, _, oy, oz, w)
            drawn[#drawn + 1] = { oy = oy, oz = oz, w = w }
        end,
        ready = function() return true end,
    }
    BR.Native = { keyLabelForCommand = function() return 'E' end }
    BR.Sfx = { play = function(k) sfx[#sfx + 1] = k end }
    BR.Inv = { local_ = function() return { slots = {}, ammo = invAmmo } end }
    BR.State = {
        match = { state = BR.MatchState.PLAYING },
        me    = { state = BR.PlayerState.ALIVE },
    }
    BR.ShopSolve = {
        priceLine = function(p, c) return ('%d %s'):format(p or 0, c or 'Volts') end,
    }
    -- GUNSHOP_STOCK IS SUPPLIED HERE AND IS NOT IN protocol.lua YET, which is
    -- exactly what the guard in client/gunshop.lua is for: with the constant
    -- absent nothing registers, `stock` stays nil, and every row shows its
    -- price. This sandbox supplies it so the stocked behavior can be asserted
    -- before the wire exists.
    BR.Net = {
        GUNSHOP_BUY    = 'br:gunshop:buy',
        GUNSHOP_BOUGHT = 'br:gunshop:bought',
        GUNSHOP_STOCK  = 'br:gunshop:stock',
        MARKET_STATE   = 'br:market:state',
    }

    function AddEventHandler(name, fn) handlers[name] = fn end
    function RegisterNetEvent() end
    function RegisterCommand(name, fn) cmds[name] = fn end
    function GetCurrentResourceName() return 'br_core' end
    -- RECORDED RATHER THAN SWALLOWED. `br:ui:sendLocal` is the only door
    -- br_core has to the page -- br_ui/client/nui.lua is the one file allowed
    -- to call SendNUIMessage -- so a no-op stub here makes every HUD envelope
    -- this file sends invisible to the suite. M5 and M6 shipped fully built on
    -- the page and unreachable from Lua underneath exactly that blind spot.
    local local_ = {}
    function TriggerEvent(name, kind, payload)
        local_[#local_ + 1] = { name = name, kind = kind, payload = payload }
    end
    --- The last `br:ui:sendLocal` of one kind, or nil.
    local function lastLocal(kind)
        for i = #local_, 1, -1 do
            local e = local_[i]
            if e.name == 'br:ui:sendLocal' and e.kind == kind then return e end
        end
        return nil
    end
    function TriggerServerEvent(name, payload)
        sent[#sent + 1] = { name = name, payload = payload }
    end
    function PlayerPedId() return 1 end
    function GetEntityCoords(e)
        if e == 1 then return me end
        return peds[e] or { x = 0.0, y = 0.0, z = 0.0 }
    end
    function DoesEntityExist(e) return (e == 1 or peds[e] ~= nil) and 1 or 0 end
    function GetGameTimer() return 1000 end
    function GetHashKey(s) return #tostring(s) end
    function IsModelValid() return 1 end
    function IsModelAPed() return 1 end
    function RequestModel() end
    function HasModelLoaded() return 1 end
    function SetModelAsNoLongerNeeded() end

    -- ═══ THE STREAMED TEXTURE DICTIONARIES BEHIND THE PER-WEAPON ICONS (M4)
    --     ═══
    --
    -- ScaleformUI's badge path never requests a dictionary -- it pushes a txd and
    -- a txn into the movie and nothing else -- so client/gunshop.lua has to load
    -- them itself, and an unloaded dictionary draws a blank badge and reports
    -- nothing at all.
    --
    -- ⚠ NOT LOADED UNTIL THE SUITE SAYS SO, which is the whole value of this
    -- stub. `dictsLoaded` starts false so the assertions can watch a cold client
    -- open the menu before the streamer has answered -- the state a fast player
    -- on a slow machine is actually in, and the one where a feature that assumed
    -- its textures were resident shows thirteen blank rows.
    --
    -- AND IT ANSWERS 1 AND 0, NOT true AND false, which is what the runtime does
    -- and what the ratchet in tools/verify.sh exists for. A stub answering Lua
    -- booleans would let a bare `if HasStreamedTextureDictLoaded(d)` pass.
    dictRequests = {}
    dictsLoaded = false
    function RequestStreamedTextureDict(d, p1)
        dictRequests[#dictRequests + 1] = { dict = d, p1 = p1 }
    end
    function HasStreamedTextureDictLoaded(d)
        if not dictsLoaded then return 0 end
        for i = 1, #dictRequests do
            if dictRequests[i].dict == d then return 1 end
        end
        return 0
    end
    -- THE COORDINATES ARE RECORDED, NOT DISCARDED. This stub used to ignore x
    -- and y, which meant the suite could not tell WHERE the clerk's floor was
    -- being solved -- and C1 moved the clerk in x and y while leaving the probe
    -- on the anchor he was moved off.
    local probes = {}
    function GetGroundZFor_3dCoord(x, y, z)
        probes[#probes + 1] = { x = x, y = y, z = z }
        return 1, z - 0.12
    end
    function CreatePed(_, _, x, y, z)
        nextPed = nextPed + 1
        peds[nextPed] = { x = x, y = y, z = z }
        return nextPed
    end
    function DeleteEntity(e) peds[e] = nil end
    function SetEntityHeading() end
    function SetEntityCoordsNoOffset(e, x, y, z) peds[e] = { x = x, y = y, z = z } end
    function PlayPedAmbientSpeechWithVoiceNative(ped, name, voice, params)
        speech[#speech + 1] =
            { ped = ped, name = name, voice = voice, params = params }
    end

    -- ═══ THE HANDOVER'S NATIVES ═══
    local props, attaches, anims, cleared = {}, {}, {}, {}
    function GetWeapontypeModel(h) return 900000 + (tonumber(h) or 0) % 1000 end
    function CreateObjectNoOffset(model, x, y, z, isNetwork, netMission)
        nextPed = nextPed + 1
        peds[nextPed] = { x = x, y = y, z = z }
        props[#props + 1] = { obj = nextPed, model = model,
                              isNetwork = isNetwork, netMission = netMission,
                              alive = true }
        return nextPed
    end
    function GetPedBoneIndex(_, id) return 40000 + id end
    function AttachEntityToEntity(obj, parent, bone)
        attaches[#attaches + 1] = { obj = obj, parent = parent, bone = bone }
    end
    function DetachEntity(obj)
        for _, p in ipairs(props) do if p.obj == obj then p.detached = true end end
    end
    function SetEntityCollision() end
    function RequestAnimDict() end
    function HasAnimDictLoaded() return 1 end
    function TaskPlayAnim(ped, dict, clip, _, _, ms, flag)
        anims[#anims + 1] =
            { ped = ped, dict = dict, clip = clip, ms = ms, flag = flag }
    end
    function ClearPedTasks(ped) cleared[#cleared + 1] = ped end
    -- WRAPPED RATHER THAN REPLACED, because the ped teardown above is the same
    -- native and both halves have to keep working.
    local baseDelete = DeleteEntity
    function DeleteEntity(e)
        baseDelete(e)
        for _, p in ipairs(props) do if p.obj == e then p.alive = false end end
    end
    Citizen = {
        -- RUN INLINE. buildClerk's thread only yields on a model request and
        -- this stub answers immediately, so running it here is the same
        -- sequence with the waiting taken out.
        CreateThread = function(fn) fn() end,
        Wait = function() end,
    }

    assert(loadfile(ROOT .. 'br_core/client/gunshop.lua'))()
    handlers['onClientResourceStart']('br_core')

    local storeById = {}
    for _, s in ipairs(G.stores) do storeById[s.id] = s end

    --- Stand at a counter and let the reconciler build its clerk.
    local function standAt(id)
        local s = storeById[id]
        me = { x = s.x, y = s.y, z = s.z }
        loops['gunshop.clerks']()
        loops['gunshop.prompt']()
    end

    --- Leave, which is what closes the menu.
    local function walkAway()
        me = { x = 0.0, y = 0.0, z = 0.0 }
        loops['gunshop.prompt']()
    end

    local function press() keys['interact'](true) end

    --- A console command prints a table by design; the suite does not want it.
    local realPrint2 = print
    local function hush(fn, ...)
        _G.print = function() end
        local okc, err = pcall(fn, ...)
        _G.print = realPrint2
        if not okc then error(err, 0) end
    end

    --- ...except when the printed lines ARE the thing under test.
    ---
    --- /brgunclerk's whole output is a block the owner pastes back into
    --- br_lib/config/gunshop.lua. A wrong number in it is not a cosmetic fault:
    --- it is a config edit he makes on our say-so, so the lines have to be
    --- readable by the suite rather than swallowed by it.
    --- @return string[] lines
    local function grab(fn, ...)
        local out = {}
        _G.print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            out[#out + 1] = table.concat(parts, ' ')
        end
        local okc, err = pcall(fn, ...)
        _G.print = realPrint2
        if not okc then error(err, 0) end
        return out
    end

    --- One captured line containing `needle`, or nil.
    local function lineWith(lines, needle)
        for _, l in ipairs(lines) do
            if l:find(needle, 1, true) then return l end
        end
        return nil
    end

    --- Every ordinary row of the built menu, keyed by its visible label.
    local function shelf()
        local out = {}
        if not lastMenu then return out end
        for _, it in ipairs(lastMenu.Items) do
            if it.ItemId ~= 6 then out[it._text] = it end
        end
        return out
    end

    --- One row by catalogue id, through the same labeller the menu used.
    local function rowItem(id)
        local r = S.rowById(select(1, G.build()), id)
        if not r then return nil end
        return shelf()[S.menuLabel(r)]
    end

    -- -----------------------------------------------------------------------
    describe('the plate says two lines now, and the second one is his')
    -- -----------------------------------------------------------------------
    standAt('pillbox')
    local plate
    for _, d in ipairs(dui) do if d.show == true then plate = d end end
    ok(plate ~= nil, 'the plate went up at the counter')
    ok(plate ~= nil and plate.hint == 'PRESS TO OPEN',
        'and carries his second line, verbatim and in his own caps (D2)',
        plate and tostring(plate.hint) or 'no plate')
    ok(plate ~= nil and plate.label == G.menuTitle,
        'the title is still config/gunshop.lua\'s one word, not a second copy '
            .. 'of it typed here (D2, M8)')

    -- -----------------------------------------------------------------------
    describe('S1: the ground probe samples where the clerk actually stands')
    -- -----------------------------------------------------------------------
    do
        -- ═══ C1 MOVED HIM AND THE PROBE STAYED BEHIND ═══
        --
        -- Owner, 2026-09-09: "let us move their position back behind the
        -- counter and to the left (the ped-s right) about 1m". The config ships
        -- clerkOffsetM -0.7 and clerkRightM 1.0, so the clerk stands about 1.2m
        -- from the anchor -- and the probe was still being fired at the anchor,
        -- which is the register he was moved OFF. His height was solved for a
        -- spot on the customer's side of the counter.
        --
        -- ON A FLAT FLOOR THE TWO AGREE AND NOTHING SHOWS, which is why this
        -- survived review: it is invisible until a counter has a step or a
        -- plinth behind it, and then the clerk is sunk into it or standing on
        -- air with nothing in any log.
        local st = storeById['pillbox']
        local wx, wy = S.clerkAt(G, st, 0.0)
        local p = probes[1]

        ok(p ~= nil, 'the floor was probed at all', #probes)
        ok(p ~= nil and math.abs(p.x - wx) < 0.001
            and math.abs(p.y - wy) < 0.001,
            'and at the CLERK\'S position, not the counter anchor he was moved '
                .. 'off (S1, C1)',
            p and ('probed %.3f,%.3f -- clerk is at %.3f,%.3f')
                :format(p.x, p.y, wx, wy) or 'no probe')

        -- AND THE TWO ARE GENUINELY DIFFERENT PLACES, which is what stops the
        -- assertion above passing on a config where both offsets are zero.
        ok(BR.Dist(wx, wy, st.x, st.y) > 0.5,
            '...and those are over half a metre apart, so the assertion above '
                .. 'is not comparing a point with itself',
            ('%.3f m'):format(BR.Dist(wx, wy, st.x, st.y)))

        -- THE START HEIGHT IS STILL THE ANCHOR'S, because probeStart is about
        -- how far ABOVE the authored floor to begin looking, and sliding a
        -- metre along that floor does not change which storey we want.
        ok(p ~= nil and math.abs(p.z - S.probeStart(G, st)) < 0.001,
            'the probe still starts from the anchor height plus the lift',
            p and ('%.3f vs %.3f'):format(p.z, S.probeStart(G, st)) or 'none')
    end

    -- -----------------------------------------------------------------------
    describe('the chrome the owner filed six reports about')
    -- -----------------------------------------------------------------------
    press()
    ok(lastMenu ~= nil and lastMenu._visible == true, 'the menu opened')
    ok(lastMenu._mouse == false,
        'M1: the cursor is off -- UIMenu:ProcessMouse returns on that flag '
            .. 'before it reaches SetMouseCursorActiveThisFrame')
    ok(lastMenu._edge == false,
        '...and so is the edge-of-screen camera swing that rides with it')
    ok(#lastMenu.InstructionalButtons == 0,
        'M9: the instructional button LIST is empty, which is what actually '
            .. 'removes them -- HasInstructionalButtons(false) is a no-op in '
            .. '5.8.1 and would have looked like a fix')
    ok(lastMenu.TxtDictionary ~= '' and lastMenu.TxtName ~= '',
        'M2: the banner has a texture at all, which is arguments six and seven '
            .. 'of UIMenu.New -- passing five is what left it a bare bar',
        ('%s / %s'):format(tostring(lastMenu.TxtDictionary),
                           tostring(lastMenu.TxtName)))
    -- ...AND NO COLOR IS PAINTED UNDER IT. It used to be the cyan, skipped on
    -- the branch where a sprite was supplied; since 2026-09-11 SetBannerColor is
    -- not called on any branch at all, so this now holds for a menu with no art
    -- as well. The movie TINTS a supplied sprite with the banner color, which is
    -- why a color here was never a bar behind the Ammu-Nation sign -- it could
    -- only have discolored it.
    ok(lastMenu._bannerColor == nil,
        'and nothing is painted under the sprite, on any branch -- the movie '
            .. 'tints the art with the banner color rather than drawing a bar')
    ok(lastMenu.Title == G.menuTitle,
        'M8: the title comes from config, so his one word changes the banner '
            .. 'and the world plate together')

    -- -----------------------------------------------------------------------
    describe('M3: top-down by category, legendary at the bottom')
    -- -----------------------------------------------------------------------
    do
        local heads = {}
        for _, it in ipairs(lastMenu.Items) do
            if it.ItemId == 6 then heads[#heads + 1] = it end
        end
        ok(#heads >= 4, 'there are category headers at all', #heads)
        for i = 1, #heads do
            if heads[i].Jumpable ~= true then
                ok(false, 'every header is jumpable, so the arrow keys skip it '
                    .. '-- a disabled row would be one the player can sit on')
                break
            end
            if i == #heads then
                ok(true, 'every header is jumpable, so the arrow keys skip it '
                    .. '-- a disabled row would be one the player can sit on')
            end
        end
        ok(heads[1] and heads[1]._text == 'Ammo',
            'the top group is the ammunition -- "the top being the most common '
                .. '... they sell"',
            heads[1] and heads[1]._text or 'none')
        ok(heads[#heads] and heads[#heads]._text == 'Legendary',
            '...and the bottom one is Legendary, in BR.RarityInfo\'s own word',
            heads[#heads] and heads[#heads]._text or 'none')

        -- ═══ AND THE AMMUNITION HEADER IS NO LONGER THE BRIGHTEST THING ON
        --     THE SHELF (owner, 2026-09-11) ═══
        --
        -- "The ammunition separator should read 'Ammo' and be no special color,
        -- same color as the ammo item rows themselves."
        --
        -- Every separator took BR.Menu.accent() -- the interface cyan, at full
        -- opacity -- and the ammunition one now takes what its own rows take.
        --
        -- ⚠ ASSERTED AGAINST A ROW, NOT AGAINST A NAMED COLOR. "Same color as
        -- the ammo item rows themselves" is a statement about two things being
        -- equal, and a test that spelled out an RGB would pass on the day the
        -- rows moved and the header did not -- which is the only failure this
        -- can actually have.
        local function sameColor(a, b)
            return type(a) == 'table' and type(b) == 'table'
               and a.a == b.a and a.r == b.r and a.g == b.g and a.b == b.b
        end
        local ammoRow = rowItem('ammo_' .. BR.AmmoType.LIGHT)
        ok(ammoRow ~= nil and sameColor(heads[1]._main, ammoRow._main),
            'the Ammo header wears exactly the color of the rows under it, '
                .. 'which is what "no special color" means here',
            ('header %s, row %s'):format(
                heads[1]._main and ('a%s r%s g%s b%s'):format(heads[1]._main.a,
                    heads[1]._main.r, heads[1]._main.g, heads[1]._main.b)
                    or 'none',
                ammoRow and ammoRow._main and ('a%s r%s g%s b%s'):format(
                    ammoRow._main.a, ammoRow._main.r, ammoRow._main.g,
                    ammoRow._main.b) or 'none'))

        -- ═══ AND THE OTHER THREE CARRY NO COLOR OF OURS EITHER ═══
        --
        -- Owner, hours after the ammunition ruling above: "What I'm referring to
        -- on the styling is the selected row and separator rows being that
        -- obnoxious light blue still", answered with "No ScaleformUI should ever
        -- use our cyan ever".
        --
        -- Rare, Epic and Legendary took BR.Menu.accent() -- #22d3ee at full
        -- opacity across the whole bar -- and now pass NOTHING, which lands them
        -- on SColor.HUD_Panel_light: FromHudColor(152), the library's own default
        -- and GTA's own palette. The stub models that fallback, which is why this
        -- can be asserted as an index rather than as an absence.
        local painted = {}
        for i = 2, #heads do
            local c = heads[i]._main
            if type(c) ~= 'table' or c.hud ~= 152 then
                painted[#painted + 1] = ('%s (%s)'):format(
                    tostring(heads[i]._text),
                    type(c) == 'table' and tostring(c.hud or c.hex) or 'none')
            end
        end
        ok(#painted == 0,
            "every rarity separator now wears the library's own panel, index "
                .. '152 out of GTA\'s palette, rather than the cyan it used to',
            #painted > 0 and table.concat(painted, ', ') or nil)

        -- ...AND NOT ONE ITEM ON THE MENU CARRIES A HEX, which is what the
        -- palette rule means at the object level rather than in the source. The
        -- stub's FromHex answers a table with a `hex` field and FromHudColor and
        -- FromArgb both answer one without, so a single cyan anywhere on the
        -- shelf shows up here whichever row it landed on.
        local hexed = {}
        for _, it in ipairs(lastMenu.Items) do
            if type(it._main) == 'table' and it._main.hex ~= nil then
                hexed[#hexed + 1] = tostring(it._text) .. ' panel'
            end
            if type(it._highlight) == 'table' and it._highlight.hex ~= nil then
                hexed[#hexed + 1] = tostring(it._text) .. ' highlight'
            end
        end
        ok(#hexed == 0,
            'and no row or header on the whole menu carries a color that came '
                .. 'from a hex, which is the only way ours could get in',
            #hexed > 0 and table.concat(hexed, ', ') or nil)

        -- ═══ THE SELECTED ROW, WHICH IS THE ONE HE RAISED TWICE ═══
        --
        -- "The selected row is way too bright blue, very harsh. Don't use that."
        --
        -- Every item took BR.Menu.accent() as its highlight and now passes nil,
        -- so UIMenuItem.New falls back to SColor.HUD_White -- FromHudColor(1),
        -- HUD_COLOUR_WHITE. ASSERTED ON EVERY ITEM rather than on one: the
        -- highlight is set at construction in one place, so the failure mode is
        -- all of them or none, and naming the count is what makes a silent
        -- regression to a per-row override visible.
        local notWhite = {}
        for _, it in ipairs(lastMenu.Items) do
            if type(it._highlight) ~= 'table' or it._highlight.hud ~= 1 then
                notWhite[#notWhite + 1] = tostring(it._text)
            end
        end
        ok(#notWhite == 0 and #lastMenu.Items > 0,
            ('all %d rows highlight in GTA\'s own white, index 1, which is the '
             .. 'library default and what the demo he liked wears')
                :format(#lastMenu.Items),
            #notWhite > 0 and table.concat(notWhite, ', ') or nil)

        -- THE ROWS ARE UNDER THE RIGHT HEADERS, which is the half a count of
        -- separators would not catch.
        local group, wrong = nil, {}
        local byLabel = {}
        for _, r in ipairs(select(1, G.build())) do byLabel[S.menuLabel(r)] = r end
        for _, it in ipairs(lastMenu.Items) do
            if it.ItemId == 6 then
                group = it._text
            else
                local r = byLabel[it._text]
                local want = (r.kind == BR.ItemKind.AMMO) and 'Ammo'
                    or BR.RarityInfo[r.rarity].label
                if group ~= want then wrong[#wrong + 1] = it._text end
            end
        end
        ok(#wrong == 0, 'and every row sits under the header for its own group',
            #wrong > 0 and table.concat(wrong, ', ') or nil)
    end

    -- -----------------------------------------------------------------------
    describe('M4 and M7: an icon on every row, and a gold price')
    -- -----------------------------------------------------------------------
    do
        local noBadge, notGold = {}, {}
        for label, it in pairs(shelf()) do
            if it._leftBadge == nil then noBadge[#noBadge + 1] = label end
            if type(it._rightLabel) ~= 'string'
                or it._rightLabel:sub(1, 8) ~= '~HC_109~' then
                notGold[#notGold + 1] = label
            end
        end
        ok(#noBadge == 0, 'M4: every row carries a left badge',
            #noBadge > 0 and table.concat(noBadge, ', ') or nil)
        ok(#notGold == 0,
            'M7: and every price is marked with the HUD gold token -- the '
                .. 'right label is pushed as a text command with no color '
                .. 'argument, so a token in the string is the only route',
            #notGold > 0 and table.concat(notGold, ', ') or nil)

        local gun  = rowItem('carbinerifle')
        local ammo = rowItem('ammo_' .. BR.AmmoType.LIGHT)
        ok(gun and gun._leftBadge == BadgeStyle.GUN,
            'a gun wears the gun badge', gun and gun._leftBadge or 'no row')
        ok(ammo and ammo._leftBadge == BadgeStyle.AMMO,
            'and an ammo row wears the ammo badge',
            ammo and ammo._leftBadge or 'no row')

        -- ⚠ AND EVERY ONE OF THE ASSERTIONS ABOVE RAN WITH THE TEXTURE
        -- DICTIONARIES NOT YET STREAMED, which is the cold-start state and is
        -- asserted rather than assumed. A per-weapon icon feature that reached
        -- for a texture the streamer had not answered for would put a blank
        -- badge on twelve of these rows and report nothing.
        ok(dictsLoaded == false,
            'the block above ran on a client whose icon dictionaries had not '
                .. 'arrived yet, and every row still had a badge')
        ok(gun and (gun.customLeftIcon == nil or gun.customLeftIcon.TXD == ''),
            'and no texture was reached for before the streamer answered -- an '
                .. 'empty pair, not a name that would draw a blank badge')
    end

    -- -----------------------------------------------------------------------
    describe('M4: the icons are the base game\'s own weapon art')
    -- -----------------------------------------------------------------------
    do
        -- ═══════════════════════════════════════════════════════════════════
        -- Owner, 2026-09-11: "As for the menu icons - how does the ScaleformUI
        -- demo menu draw them? Those gfx are built into the base game. We
        -- should use those."
        -- ═══════════════════════════════════════════════════════════════════
        --
        -- He was right and the previous round's answer was wrong. What makes
        -- this hard to test is what makes it hard to get right: A WRONG TEXTURE
        -- NAME DRAWS NOTHING AND REPORTS NO ERROR. So does a wrong dictionary,
        -- so does a dictionary nobody requested, and so does a key in the art
        -- table that is not a real shop row id. All four are invisible from
        -- inside the game and all four are visible from here.
        local ICONS = G.weaponIcons
        local art = ICONS.art

        -- ═══ A. EVERY KEY IN THE ART TABLE IS A GUN THE SHOP ACTUALLY SELLS
        --     ═══
        --
        -- ⚠ THE FAILURE THIS CATCHES HAS NO SYMPTOM. `carbinrifle` with the
        -- letter missing is not an error, it is a table entry nothing ever looks
        -- up, and the row it was meant for keeps the generic badge exactly as if
        -- the feature had never been written. The catalogue is DERIVED from the
        -- loot table, so this also catches a gun being priced out of the shop
        -- and its icon being left behind.
        local catalogue = select(1, G.build())
        local strays = {}
        for id in pairs(art) do
            if S.rowById(catalogue, id) == nil then
                strays[#strays + 1] = id
            end
        end
        ok(#strays == 0,
            'every id in the art table is a row the shop really builds',
            #strays > 0 and table.concat(strays, ', ') or nil)

        -- ═══ B. EVERY DICTIONARY THE ART NAMES IS ONE THAT GETS REQUESTED ═══
        --
        -- ScaleformUI requests nothing for a badge -- it pushes a txd and a txn
        -- into the movie and stops -- so a dictionary this file names and never
        -- asks the streamer for is a blank badge on every row that uses it.
        local wanted, asked = {}, {}
        for _, a in pairs(art) do wanted[a.txd] = true end
        for _, r in ipairs(dictRequests) do asked[r.dict] = true end
        local unasked = {}
        for d in pairs(wanted) do
            if not asked[d] then unasked[#unasked + 1] = d end
        end
        ok(#unasked == 0,
            'every dictionary the art table names is requested from the '
                .. 'streamer, because the library never will',
            #unasked > 0 and table.concat(unasked, ', ') or nil)

        -- ...AND NOTHING ELSE IS. A dictionary held for no row is memory spent
        -- for nothing on every client that walks past a counter.
        local spare = {}
        for d in pairs(asked) do
            if not wanted[d] then spare[#spare + 1] = d end
        end
        ok(#spare == 0, 'and no dictionary is held that no row uses',
            #spare > 0 and table.concat(spare, ', ') or nil)

        -- p1 IS FALSE, which is what Rockstar's own mp_weapons script passes for
        -- these exact three dictionaries. The argument is undocumented in
        -- citizenfx/natives and the vendored library passes true elsewhere.
        local badP1 = false
        for _, r in ipairs(dictRequests) do
            if r.p1 ~= false then badP1 = true end
        end
        ok(not badP1, 'and each is asked for the way the base game asks for it')

        -- ═══ C. WITH THEM LOADED, THE REAL ART LANDS ON THE RIGHT ROWS ═══
        walkAway()
        handlers[BR.Net.MARKET_STATE]({ balance = 999999 })
        dictsLoaded = true
        standAt('pillbox')
        press()

        local rifle = rowItem('carbinerifle')
        ok(rifle ~= nil and rifle.customLeftIcon ~= nil
            and rifle.customLeftIcon.TXD == 'mpweaponsgang0_small'
            and rifle.customLeftIcon.TXN == 'w_ar_carbinerifle',
            'a Carbine Rifle wears the game\'s own carbine icon',
            rifle and rifle.customLeftIcon
                and (rifle.customLeftIcon.TXD .. '/' .. rifle.customLeftIcon.TXN)
                or 'no icon')

        -- ...AND THE LIBRARY IS TOLD IT IS A CUSTOM BADGE. CustomLeftBadge sets
        -- `_leftBadge` to BadgeStyle.CUSTOM on its way past, and the movie is
        -- handed both values on every redraw; a row still carrying GUN beside a
        -- texture name is the ambiguity BR.Menu.leftBadge exists to remove.
        ok(rifle ~= nil and rifle._leftBadge == BadgeStyle.CUSTOM,
            'and the enum badge is stood down for it',
            rifle and tostring(rifle._leftBadge) or 'no row')

        -- THE MK2 WEARS ITS BASE GUN'S ART, which is the one line in the config
        -- table that is a judgment rather than a lookup.
        local mk2 = rowItem('carbinemk2')
        ok(mk2 ~= nil and mk2.customLeftIcon ~= nil
            and mk2.customLeftIcon.TXN == 'w_ar_carbinerifle',
            'and a Carbine MK2 wears the same carbine, deliberately')

        -- ═══ D. A GUN WITH NO ART IN THE BASE GAME KEEPS THE GENERIC BADGE
        --     ═══
        --
        -- Thirteen of the twenty-five on sale are post-2013 weapons Rockstar
        -- never drew an icon for, and its own lookup answers the empty string
        -- for every one of them. Falling back is the feature, not a gap.
        local none = rowItem('gusenberg')
        ok(none ~= nil and none._leftBadge == BadgeStyle.GUN,
            'a Gusenberg, which the base game has no icon for, keeps the gun '
                .. 'badge', none and tostring(none._leftBadge) or 'no row')
        ok(none ~= nil and (none.customLeftIcon == nil
            or none.customLeftIcon.TXD == ''),
            'and carries no texture name at all, rather than a plausible one')

        -- AMMO ROWS ARE UNTOUCHED. There is no per-pool art and the kind badge
        -- was always the right answer for them.
        local ammo = rowItem('ammo_' .. BR.AmmoType.LIGHT)
        ok(ammo ~= nil and ammo._leftBadge == BadgeStyle.AMMO,
            'and an ammo row still wears the ammo badge')

        -- ═══ E. ⚠ THE ICON WINS THE SLOT, AND IT KEEPS IT WHILE LOCKED ═══
        --
        -- THIS IS THE ASSERTION THE WHOLE FEATURE TURNS ON, AND IT USED TO
        -- ASSERT THE OPPOSITE. There is one badge slot; the padlock took it on
        -- every locked row, and "cannot afford" is most rows for most of a
        -- match, so the icons were least visible exactly while somebody was
        -- browsing.
        --
        -- Owner, 2026-09-11: "If a weapon is both iconed and locked, the icon
        -- should remain on the left of the row before the name as normal."
        -- Confirmed on both locked states, so the padlock does not take the slot
        -- in either.
        --
        -- A COLD BALANCE IS THE ORDINARY PATH AND NOT A CORNER. The shelf is
        -- repainted on every balance change, so a client that spends down to
        -- nothing repaints all thirty rows into this state.
        walkAway()
        handlers[BR.Net.MARKET_STATE]({ balance = 0 })
        standAt('pillbox')
        press()

        local broke = rowItem('carbinerifle')
        ok(broke ~= nil and broke.customLeftIcon ~= nil
            and broke.customLeftIcon.TXD == 'mpweaponsgang0_small'
            and broke.customLeftIcon.TXN == 'w_ar_carbinerifle',
            'a Carbine Rifle they cannot afford KEEPS its carbine icon',
            broke and broke.customLeftIcon
                and ('%s/%s'):format(tostring(broke.customLeftIcon.TXD),
                                     tostring(broke.customLeftIcon.TXN))
                or 'no icon field')
        ok(broke ~= nil and broke._leftBadge == BadgeStyle.CUSTOM,
            '...and the enum badge is still stood down for it, so no padlock id '
                .. 'rides into the movie beside the texture',
            broke and tostring(broke._leftBadge) or 'no row')

        -- ═══ AND THE PADLOCK IS NOT ON ANY ROW ANYWHERE, WHICH A PER-ROW
        --     ASSERTION WOULD NOT SAY ═══
        --
        -- Thirteen of the twenty-five guns on sale have no icon in the base
        -- game. A Carbine keeping its art proves nothing about those, and
        -- leaving the lock on exactly the rows that have no icon would be the
        -- same slot fight one size smaller -- half the shelf padlocked and half
        -- not, at a balance of zero.
        local padlocked = {}
        for label, it in pairs(shelf()) do
            if it._leftBadge == BadgeStyle.LOCK then
                padlocked[#padlocked + 1] = label
            end
        end
        ok(#padlocked == 0,
            'and with a balance of zero NOT ONE row on the shelf wears the '
                .. 'padlock -- including the thirteen guns with no icon at all',
            #padlocked > 0 and table.concat(padlocked, ', ') or nil)

        -- ...AND THE ART IS STILL THERE when they can pay, which is what makes
        -- the block above a statement about the lock rather than about the
        -- streamer having dropped the dictionaries.
        walkAway()
        handlers[BR.Net.MARKET_STATE]({ balance = 999999 })
        standAt('pillbox')
        press()
        local rich = rowItem('carbinerifle')
        ok(rich ~= nil and rich.customLeftIcon ~= nil
            and rich.customLeftIcon.TXN == 'w_ar_carbinerifle',
            'and an affordable one wears the same icon, so nothing about the '
                .. 'balance touches the badge slot at all')

        -- ═══ E2. ALL TWELVE, ON A REAL SHELF, COUNTED ═══
        --
        -- ⚠ THE ASSERTIONS ABOVE NAME THREE ROWS. Part A proves every art KEY is
        -- a row the shop builds and part B proves every dictionary is requested,
        -- and neither of those is the same claim as "the texture reached the
        -- item". A row dropped between the catalogue and the menu, or an
        -- `iconFor` that answered nil for eleven of the twelve, passes both.
        --
        -- A REAL COUNT RATHER THAN A ZERO-LENGTH LIST. `#missing == 0` is also
        -- true when the loop never ran, which is how a suite comes to agree with
        -- an empty feature.
        local wantIcon, gotIcon, missIcon = 0, 0, {}
        for id, a in pairs(art) do
            wantIcon = wantIcon + 1
            local it = rowItem(id)
            if it ~= nil and it.customLeftIcon ~= nil
                and it.customLeftIcon.TXD == a.txd
                and it.customLeftIcon.TXN == a.txn
                and it._leftBadge == BadgeStyle.CUSTOM then
                gotIcon = gotIcon + 1
            else
                missIcon[#missIcon + 1] = id
            end
        end
        ok(wantIcon == 12,
            'the art table is the eight evidenced icons plus the four MK2s',
            wantIcon)
        ok(gotIcon == wantIcon,
            '...and every one of them is on its own row, as the exact pair the '
                .. 'config names',
            #missIcon > 0 and table.concat(missIcon, ', ') or gotIcon)

        -- ═══ F. ONE SWITCH PUTS IT ALL BACK ═══
        --
        -- ⚠ NOBODY HAS SEEN THIS ON A SCREEN. The names are evidenced; how the
        -- movie's badge slot treats a 2:1 base game texture is not, and cannot
        -- be without running the game. `enabled = false` is the line that undoes
        -- the whole feature without touching anything else.
        --
        -- ⚠ TESTED AT A BALANCE OF ZERO, WHICH IS THE STATE THAT USED TO HIDE A
        -- BUG HERE. While the padlock won the badge slot, EVERY row of a broke
        -- client wore BadgeStyle.LOCK whether the feature was on or off, so this
        -- block would have passed against an `enabled` flag that did nothing.
        -- Now the icon owns the slot in that state too, so the switch is the
        -- only thing that can put the kind badge back.
        ICONS.enabled = false
        walkAway()
        handlers[BR.Net.MARKET_STATE]({ balance = 0 })
        standAt('pillbox')
        press()

        local offKind, offArt = 0, {}
        for id in pairs(art) do
            local it = rowItem(id)
            if it ~= nil and it._leftBadge == BadgeStyle.GUN
                and (it.customLeftIcon == nil or it.customLeftIcon.TXD == '') then
                offKind = offKind + 1
            else
                offArt[#offArt + 1] = id
            end
        end
        ok(offKind == wantIcon,
            'enabled = false puts all twelve back on the kind badge and leaves '
                .. 'no texture behind, at a balance of zero',
            #offArt > 0 and table.concat(offArt, ', ') or offKind)

        local offPad = {}
        for label, it in pairs(shelf()) do
            if it._leftBadge == BadgeStyle.LOCK then
                offPad[#offPad + 1] = label
            end
        end
        ok(#offPad == 0,
            '...and turning the icons off does not bring the padlock back, '
                .. 'because the owner retired it separately',
            #offPad > 0 and table.concat(offPad, ', ') or nil)

        ICONS.enabled = true
        handlers[BR.Net.MARKET_STATE]({ balance = 999999 })
    end

    -- -----------------------------------------------------------------------
    describe('L5: an ammo row says what it is for, and nothing else does')
    -- -----------------------------------------------------------------------
    do
        local light = rowItem('ammo_' .. BR.AmmoType.LIGHT)
        ok(light ~= nil and light._Description ~= nil
            and light._Description ~= '',
            'the focused ammo row has a description at all')
        -- ═══ ALL WEAPONS, NOT JUST THE ONES ON SALE ═══
        --
        -- His reason is the LOADOUT, and a loadout is mostly floor loot. The
        -- shop only stocks RARE and above, so a list drawn from the catalogue
        -- would omit every pistol and SMG the map hands out -- which is most of
        -- what the player standing there is carrying. `Pistol` is COMMON and is
        -- not for sale at any counter, so its presence is the proof.
        ok(light ~= nil and light._Description:find('Pistol', 1, true) ~= nil,
            'and it lists weapons the shop does NOT sell, because the customer '
                .. 'is carrying those too',
            light and light._Description or 'none')
        ok(S.rowById(select(1, G.build()), 'pistol') == nil,
            '...proven by the Pistol not being on sale anywhere')

        -- ═══ AND THE AIRDROP GUNS, WHICH IT LEFT OUT ENTIRELY ═══
        --
        -- BR.GunshopSolve.ammoUsers takes SOURCE TABLES and was built and tested
        -- for exactly this, against both BR.Config.Weapons and
        -- BR.Config.AirdropWeapons. This file rolled a private scan over the
        -- first of those alone, so every airdrop weapon was missing from every
        -- description -- two answers to one question with the shorter one
        -- shipped. All four airdrop guns feed on HEAVY, which is the pool a
        -- player who has just opened a crate is standing at the counter to buy.
        local heavy = rowItem('ammo_' .. BR.AmmoType.HEAVY)
        ok(heavy ~= nil and heavy._Description ~= nil
            and heavy._Description ~= '', 'the heavy row has a description')

        local missing = {}
        for _, w in ipairs(BR.Config.AirdropWeapons or {}) do
            if w.ammo == BR.AmmoType.HEAVY
               and (heavy == nil or heavy._Description == nil
                    or heavy._Description:find(w.label, 1, true) == nil) then
                missing[#missing + 1] = w.label
            end
        end
        ok(#missing == 0,
            'and it names every airdrop weapon that feeds on the pool (L5)',
            #missing > 0
                and ('missing: ' .. table.concat(missing, ', ')
                     .. ' -- description is: '
                     .. tostring(heavy and heavy._Description))
                or nil)

        -- THE TWO TABLES ARE GENUINELY SEPARATE, which is what stops the
        -- assertion above passing on a config where the airdrop guns happen to
        -- be in the ordinary array as well. That separation is deliberate and
        -- documented -- an airdrop gun is not something the ground rolls.
        local inOrdinary = 0
        for _, a in ipairs(BR.Config.AirdropWeapons or {}) do
            for _, w in ipairs(BR.Config.Weapons or {}) do
                if w.id == a.id then inOrdinary = inOrdinary + 1 end
            end
        end
        ok(inOrdinary == 0,
            '...and none of them is in BR.Config.Weapons, so the second source '
                .. 'table is the only way they could have got there',
            inOrdinary)

        local gun = rowItem('carbinerifle')
        ok(gun ~= nil and (gun._Description == nil or gun._Description == ''),
            'a WEAPON row still says nothing -- he asked for this on ammo rows '
                .. 'only, and a sentence per gun would be thirty pieces of '
                .. 'copy he did not ask for')
    end

    -- -----------------------------------------------------------------------
    describe('P1: the clerk speaks when the menu opens')
    -- -----------------------------------------------------------------------
    ok(#speech >= 1, 'something was said', #speech)
    ok(speech[#speech] and speech[#speech].name == 'SHOP_SELL',
        'and it is the line whose NAME is the thing he asked for -- '
            .. '"something about selling product"',
        speech[#speech] and speech[#speech].name or 'nothing')
    ok(speech[#speech] and speech[#speech].voice
        == 'S_M_Y_AMMUCITY_01_WHITE_MINI_01',
        'named with the voice that HAS that line: the model declares a voice '
            .. 'GROUP whose two members carry different speech sets, so an '
            .. 'unnamed voice is a coin flip',
        speech[#speech] and speech[#speech].voice or 'none')

    -- -----------------------------------------------------------------------
    describe('L1: a row they cannot afford is shaded but still pressable')
    -- -----------------------------------------------------------------------
    do
        walkAway()
        handlers[BR.Net.MARKET_STATE]({ balance = 0 })
        standAt('pillbox')
        press()
        local gun = rowItem('carbinerifle')

        -- ═══ THE SHADE IS WHAT SAYS "LOCKED" NOW, AND IT IS THE ITEM'S OWN
        --     PANEL ═══
        --
        -- Owner, 2026-09-11: "the row should be shaded differently like it's
        -- greyed out/disabled." It cannot be UIMenuItem:Enabled -- see the note
        -- below, which is the same reason it could not be before -- so it is
        -- `_mainColor`, the field the rarity tint paints, and a row wears one or
        -- the other.
        --
        -- ASSERTED AGAINST BR.Menu's OWN TWO ANSWERS rather than against
        -- literals, so the two dials in that file stay tunable and this stays a
        -- statement about WHICH of them a locked row gets.
        local shade = BR.Menu.disabledColor()
        local rare  = BR.Menu.rarityColor(
            S.rowById(select(1, G.build()), 'carbinerifle').rarity)
        local function same(a, b)
            return a ~= nil and b ~= nil and a.a == b.a and a.r == b.r
                and a.g == b.g and a.b == b.b
        end
        ok(not same(shade, rare),
            'the disabled shade and a rarity tint are actually different '
                .. 'colours, so the assertions below can tell them apart')
        ok(gun ~= nil and same(gun._main, shade),
            'a row they cannot afford wears the disabled shade',
            gun and gun._main and ('a%s r%s g%s b%s'):format(gun._main.a,
                gun._main.r, gun._main.g, gun._main.b) or 'no colour')

        -- ═══ AND IT KEEPS ITS GOLD PRICE, WHICH IS THE HALF HE SPELLED OUT
        --     ═══
        --
        -- Owner, 2026-09-11: in stock but unaffordable keeps the price "so the
        -- player can see what they are saving toward". Only OUT OF STOCK
        -- replaces it. A shade that also blanked the price would read as a
        -- sold-out shelf the moment somebody spent their last Volts.
        ok(gun ~= nil and type(gun._rightLabel) == 'string'
            and gun._rightLabel:sub(1, 8) == '~HC_109~',
            '...and still shows its price, in gold',
            gun and tostring(gun._rightLabel) or 'no row')
        ok(gun ~= nil and gun._rightLabel ~= nil
            and gun._rightLabel:find(G.outOfStockLabel, 1, true) == nil,
            '...and does NOT say Out of Stock, because it is in stock',
            gun and tostring(gun._rightLabel) or 'no row')

        -- ═══ AND THIS IS WHY IT IS NOT A DISABLED ROW ═══
        --
        -- He asked for a lock AND a toast on the same press. UIMenu:SelectItem
        -- returns on the Enabled check BEFORE Item.Activated runs, so a
        -- disabled row can never reach the server -- and the toast has to be
        -- composed by the server, which is the half that holds the ledger.
        ok(gun ~= nil and gun._Enabled ~= false,
            '...and the row still reaches the server, because a disabled row '
                .. 'cannot raise the toast he asked for')
        gun.Activated()
        ok(sent[#sent] and sent[#sent].name == BR.Net.GUNSHOP_BUY
            and sent[#sent].payload.id == 'carbinerifle',
            'pressing it asks the server, which is the half that can say why '
                .. 'not')

        walkAway()
        handlers[BR.Net.MARKET_STATE]({ balance = 999999 })
        standAt('pillbox')
        press()
        local rich = rowItem('carbinerifle')

        -- ⚠ THE SHADE COMES OFF AGAIN, AND THIS IS THE ASSERTION THAT MAKES IT
        -- A STATE RATHER THAN A ONE-WAY DOOR.
        --
        -- The row is repainted on every balance change, so both arms of the
        -- shade have to produce a colour: an arm that answered nil would leave
        -- the shade on -- `UIMenuItem:MainColor(nil)` is the library's GETTER --
        -- and the symptom would be a permanently dead-looking row a player can
        -- buy from. Its rarity is the thing it must come back to, not merely
        -- "not the shade".
        ok(rich ~= nil and same(rich._main, rare),
            'and the shade comes off for its own rarity tint when they can pay',
            rich and rich._main and ('a%s r%s g%s b%s'):format(rich._main.a,
                rich._main.r, rich._main.g, rich._main.b) or 'no colour')
        ok(rich ~= nil and rich._leftBadge ~= BadgeStyle.LOCK,
            'and no padlock was involved on either side of that',
            rich and tostring(rich._leftBadge) or 'no row')
    end

    -- -----------------------------------------------------------------------
    describe('M5 and M6: the page is told the menu is up, and Lua is the teller')
    -- -----------------------------------------------------------------------
    do
        -- ═══ THE ASSERTION THAT WOULD HAVE CAUGHT A WHOLE DEAD FEATURE ═══
        --
        -- Owner, 2026-09-09, M5 and M6: the squad panel goes away while the
        -- shop menu is open, and his Volts balance stays visible bottom-right
        -- while it is. Both are decided in Hud.tsx off one store flag,
        -- `gunshopMenu`, and ui-src/scripts/check-ui.mjs's R15 proves the page
        -- half thoroughly. NOTHING PROVED THE SENDER, and there was not one:
        -- the string `gunshopmenu` appeared in no .lua file in the tree, so the
        -- flag was false for the life of every session and both requests were
        -- unreachable code that reviewed as finished.
        walkAway()
        standAt('pillbox')
        local before = lastLocal('gunshopmenu')
        ok(before == nil or before.payload.open == false,
            'standing at the counter does not raise it -- the world plate is '
                .. 'not the menu')

        local mark = #local_
        press()
        local up = lastLocal('gunshopmenu')
        ok(up ~= nil,
            'opening the menu sends a gunshopmenu envelope at all -- the whole '
                .. 'of M5 and M6 hangs off this one line')
        ok(up ~= nil and up.payload.open == true,
            '...and it says the menu is open',
            up and tostring(up.payload.open) or 'nothing sent')

        -- ═══ AND IT GOES OUT BEFORE THE PLATE COMES DOWN ═══
        --
        -- Hud.tsx raises the Volts readout on `shopPlate || gunshopMenu`, and
        -- openMenu lowers shopPlate. Sending this second would leave both false
        -- for one envelope and blink the balance off and back on at the exact
        -- moment M6 asks for it to hold.
        local iUp, iPlateDown
        for i = mark + 1, #local_ do
            local e = local_[i]
            if e.name == 'br:ui:sendLocal' then
                if e.kind == 'gunshopmenu' and e.payload.open == true then
                    iUp = iUp or i
                elseif e.kind == 'shopplate' and e.payload.show == false then
                    iPlateDown = iPlateDown or i
                end
            end
        end
        ok(iPlateDown ~= nil, 'the plate does come down with the menu up')
        ok(iUp ~= nil and iPlateDown ~= nil and iUp < iPlateDown,
            '...and the menu flag was raised first, so the balance never '
                .. 'blinks between the two',
            ('menu at %s, plate at %s'):format(tostring(iUp),
                                               tostring(iPlateDown)))

        walkAway()
        local down = lastLocal('gunshopmenu')
        ok(down ~= nil and down.payload.open == false,
            'and walking away puts the squad panel back',
            down and tostring(down.payload.open) or 'nothing sent')
    end

    -- -----------------------------------------------------------------------
    describe("S5: the library's own Back button reaches our flag")
    -- -----------------------------------------------------------------------
    do
        -- ═══ A COUNTER THAT WENT DEAD UNTIL YOU WALKED AWAY FROM IT ═══
        --
        -- UIMenu:GoBack takes the menu down through the library alone --
        -- MenuHandler:CloseAndClearHistory -> Visible(false) -- and touched no
        -- state of ours. `menuOpen` stayed TRUE with nothing on screen, and the
        -- TICK pass reads it before anything else: the plate stayed down, and
        -- the interact key returns early while it is set. So pressing Back left
        -- the player standing at a counter that would not open again, and the
        -- only cure was to walk out of reach so `best ~= menuStore` closed a
        -- menu that had already closed itself.
        walkAway()
        standAt('pillbox')
        press()
        ok(lastMenu ~= nil and lastMenu._visible == true, 'the menu is up')
        ok(BR.Gunshop.busy() == true, 'and this file agrees it is busy')

        lastMenu:GoBack()
        ok(lastMenu._visible == false, 'the library took the menu down')
        ok(BR.Gunshop.busy() == false,
            "...and our flag came down with it, without the player having to "
                .. 'walk away (S5)')

        local back = lastLocal('gunshopmenu')
        ok(back ~= nil and back.payload.open == false,
            'so the squad panel comes back on Back, not just on walk-away',
            back and tostring(back.payload.open) or 'nothing sent')

        -- THE COUNTER IS ALIVE AGAIN, which is the symptom rather than the
        -- flag: one TICK pass and the world plate is back up.
        local mark = #dui
        loops['gunshop.prompt']()
        local reraised = false
        for i = mark + 1, #dui do
            if dui[i].show == true then reraised = true end
        end
        ok(reraised, 'the plate comes back on the very next tick')

        -- AND THE KEY WORKS. `if menuOpen then return end` is the first line of
        -- the interact handler, so a stale flag deadens the press itself.
        press()
        ok(lastMenu._visible == true, 'and pressing E opens it again')
        walkAway()
    end

    -- -----------------------------------------------------------------------
    describe('L2: a full ammo pool is locked out')
    -- -----------------------------------------------------------------------
    do
        invAmmo[BR.AmmoType.LIGHT] = BR.Config.AmmoCaps[BR.AmmoType.LIGHT]
        walkAway()
        standAt('pillbox')
        press()
        local light = rowItem('ammo_' .. BR.AmmoType.LIGHT)
        local heavy = rowItem('ammo_' .. BR.AmmoType.HEAVY)

        -- THE THIRD LOCKED STATE, AND IT FALLS OUT OF HIS RULE RATHER THAN
        -- NEEDING ONE. A full pool is IN STOCK, so it keeps its price and takes
        -- the shade -- the same pair an unaffordable row gets. He wrote the rule
        -- for the other two and this is what it says about this one.
        local shade2 = BR.Menu.disabledColor()
        local function same2(a, b)
            return a ~= nil and b ~= nil and a.a == b.a and a.r == b.r
                and a.g == b.g and a.b == b.b
        end
        ok(light ~= nil and same2(light._main, shade2),
            'the pool they are already carrying the maximum of is shaded')
        ok(heavy ~= nil and not same2(heavy._main, shade2),
            '...and the one they are not is not')
        ok(light ~= nil and light._leftBadge == BadgeStyle.AMMO,
            '...and it keeps its ammo badge rather than losing it to a padlock',
            light and tostring(light._leftBadge) or 'no row')
        ok(light ~= nil and type(light._rightLabel) == 'string'
            and light._rightLabel:sub(1, 8) == '~HC_109~',
            '...and keeps its gold price, because ammo is never out of stock',
            light and tostring(light._rightLabel) or 'no row')
        ok(light ~= nil and light._Enabled ~= false,
            'and it is still pressable, so the server can refuse it in the '
                .. 'same words a full pickup already uses')
        invAmmo[BR.AmmoType.LIGHT] = nil
    end

    -- -----------------------------------------------------------------------
    describe('S3 and S4: an empty shelf, and a clerk who says so')
    -- -----------------------------------------------------------------------
    do
        local all = select(1, G.build())
        local out = {}
        for _, r in ipairs(all) do
            if r.kind == BR.ItemKind.WEAPON then out[r.id] = 0 end
        end
        -- A COUNT ON AN AMMO ROW IS IGNORED RATHER THAN OBEYED. "They will have
        -- no limited stock on ammo."
        out['ammo_' .. BR.AmmoType.LIGHT] = 0

        walkAway()
        handlers[BR.Net.GUNSHOP_STOCK]({ stores = { pillbox = out }, full = true })
        standAt('pillbox')
        press()

        local gun = rowItem('carbinerifle')
        ok(gun ~= nil and gun._rightLabel == '~HC_3~Out of Stock',
            'S3: the price is replaced by his own words, verbatim, in grey',
            gun and gun._rightLabel or 'no row')

        -- ═══ GREY, AND NOT THE GOLD THE PRICE WEARS ═══
        --
        -- Owner, 2026-09-11: "instead of a gold price text, we'll show a grey
        -- 'Out of stock' text." A right label is pushed as a GTA text command
        -- with no colour argument, so a `~HC_n~` token inside the string is the
        -- only route there is -- the same one the gold price already takes.
        -- ASSERTED AS "not the price token" as well as "is the grey one",
        -- because a sold-out row that kept gold is exactly the failure that
        -- would look like nothing had changed.
        ok(gun ~= nil and gun._rightLabel ~= nil
            and gun._rightLabel:sub(1, 8) ~= '~HC_109~',
            '...and NOT in the gold the price wears',
            gun and gun._rightLabel or 'no row')
        -- ═══ AND THEY COME FROM WHERE HE PUT THEM ═══
        --
        -- config/gunshop.lua authors `outOfStockLabel` for exactly this, under
        -- a block saying nothing in it may be tidied -- "the capital letters in
        -- 'Out of Stock' -- all his" -- and it had no reader: the client typed
        -- the phrase a second time. One string with two representations, so an
        -- edit to the config would have changed nothing on screen and nothing
        -- would have said why. Asserting equality with the CONFIG rather than
        -- with a literal is what makes this a link instead of a coincidence.
        ok(gun ~= nil and gun._rightLabel ~= nil
            and gun._rightLabel:sub(-#G.outOfStockLabel) == G.outOfStockLabel,
            "...read from config's outOfStockLabel, so his edit is one edit",
            ('row %s vs config %s'):format(
                tostring(gun and gun._rightLabel), tostring(G.outOfStockLabel)))
        ok(readFile(ROOT .. 'br_core/client/gunshop.lua')
            :find('G.outOfStockLabel', 1, true) ~= nil,
            'and the client names that field rather than the words')
        ok(gun ~= nil and gun._Enabled == false,
            '...and the row is genuinely locked. He asked for no toast on this '
                .. 'one, so disabling it is right: the library plays its error '
                .. 'beep and nothing else happens')
        -- ⚠ AND IT KEEPS ITS ICON WHILE IT IS SOLD OUT. This asserted the
        -- padlock until 2026-09-11. A Carbine Rifle is one of the guns the base
        -- game has art for, and an empty shelf is the state where the MOST rows
        -- are locked at once -- so it is the case where a lock that took the
        -- badge slot cost the most icons.
        ok(gun ~= nil and gun._leftBadge == BadgeStyle.CUSTOM
            and gun.customLeftIcon ~= nil
            and gun.customLeftIcon.TXN == 'w_ar_carbinerifle',
            'and it keeps its weapon icon, rather than losing it to a padlock',
            gun and tostring(gun._leftBadge) or 'no row')

        -- AND IT IS SHADED, which is the other half of his sentence about this
        -- exact state: "Also, the row should be shaded differently like it's
        -- greyed out/disabled."
        local shade3 = BR.Menu.disabledColor()
        ok(gun ~= nil and gun._main ~= nil and shade3 ~= nil
            and gun._main.a == shade3.a and gun._main.r == shade3.r
            and gun._main.g == shade3.g and gun._main.b == shade3.b,
            'and it is shaded as disabled, not merely labelled')

        local light = rowItem('ammo_' .. BR.AmmoType.LIGHT)
        ok(light ~= nil and light._Enabled ~= false
            and light._rightLabel ~= nil
            and light._rightLabel:find(G.outOfStockLabel, 1, true) == nil,
            'ammo is never sold out, whatever the ledger says about it')

        ok(speech[#speech] and speech[#speech].name == 'SHOP_OUT_OF_STOCK',
            'S4: with every gun gone the clerk plays the line whose name is '
                .. 'exactly that case, rather than a sentence we wrote for him',
            speech[#speech] and speech[#speech].name or 'nothing')

        -- ANOTHER COUNTER IS NOT AFFECTED, which is S2 in one assertion: the
        -- ledger is per store and the menu is repainted per open.
        walkAway()
        standAt('hawick')
        press()
        local elsewhere = rowItem('carbinerifle')
        ok(elsewhere ~= nil and elsewhere._rightLabel ~= nil
            and elsewhere._rightLabel:find(G.outOfStockLabel, 1, true) == nil,
            'S2: the shelf is per counter -- walking to another shop repaints '
                .. 'the same one menu against that shop\'s ledger')

        -- ═══ A DELTA IS MERGED, NOT ASSIGNED ═══
        --
        -- The shelf is shared: every client in the match is told when anybody
        -- buys anything, as one counter and one row with no `full` flag.
        -- Assigning that would empty the other ten counters the moment a
        -- stranger bought a rifle somewhere else, and the symptom would be a
        -- shop that goes blank for no reason the player can see.
        handlers[BR.Net.GUNSHOP_STOCK](
            { stores = { hawick = { carbinerifle = 2 } } })
        walkAway()
        standAt('pillbox')
        press()
        local still = rowItem('carbinerifle')
        ok(still ~= nil and still._rightLabel ~= nil
            and still._rightLabel:find(G.outOfStockLabel, 1, true) ~= nil,
            'a purchase at another counter does not restock this one')
    end

    -- -----------------------------------------------------------------------
    describe('P2: the handover, and what is skipped for ammo')
    -- -----------------------------------------------------------------------
    do
        walkAway()
        handlers[BR.Net.GUNSHOP_STOCK]({ stores = {}, full = true })
        standAt('pillbox')
        press()

        local before = #speech
        handlers[BR.Net.GUNSHOP_BOUGHT]({ row = 'carbinerifle' })
        ok(#speech == before + 1 and speech[#speech].name == 'GUNSH_BOUGHT',
            'a gun purchase gets a remark from the clerk',
            speech[#speech] and speech[#speech].name or 'nothing')
        ok(speech[#speech].voice == 'S_M_Y_AMMUCITY_01_WHITE_01',
            '...from the FULL voice, which is the bank that has that line -- '
                .. 'the MINI voice does not')
        ok(sfx[#sfx] == G.cue, 'and the purchase cue still plays')

        ok(#props == 1, 'and a prop was put in his hand', #props)
        -- ═══ NOT A NETWORK ENTITY, AND THAT IS THE ONE THING HE ASKED FOR THAT
        --     CANNOT BE BUILT ═══
        --
        -- `sv_entityLockdown relaxed` refuses a client-created networked entity
        -- outright, and even with it off the clerk himself is a LOCAL ped that
        -- exists on one machine -- so there is no handle for a remote viewer to
        -- attach anything to. This assertion is what stops somebody "fixing"
        -- that flag later and getting a prop that silently never appears.
        ok(props[1].isNetwork == false,
            '...client-local, because a networked one would be deleted by the '
                .. 'platform before any resource saw it')
        -- THE SAME PED THE REMARK CAME OUT OF, which is what ties the prop to
        -- the clerk rather than to some entity that merely exists.
        ok(#attaches == 1 and attaches[1].obj == props[1].obj
            and attaches[1].parent == speech[#speech].ped
            and attaches[1].parent ~= PlayerPedId(),
            'attached to the clerk who just spoke, not to the player')
        ok(#attaches == 1 and attaches[1].bone == 40000 + 57005,
            '...at the INDEX GetPedBoneIndex returned for SKEL_R_Hand, never '
                .. 'the bone id itself, which attaches to the wrong bone in '
                .. 'silence',
            #attaches == 1 and attaches[1].bone or 'none')
        ok(#anims == 1 and anims[1].clip == 'givetake1_a',
            'the give gesture plays', #anims == 1 and anims[1].clip or 'none')
        ok(#anims == 1 and anims[1].flag == 48,
            '...upper body only, so a counter clerk cannot walk out of position')
        ok(props[1].detached == true and props[1].alive == false,
            'P2 step 4: and the prop is detached and deleted when he is done')
        ok(#cleared >= 1, '...and his tasks cleared with it')

        before = #speech
        local n = #sfx
        local hadProps = #props
        handlers[BR.Net.GUNSHOP_BOUGHT]({ row = 'ammo_' .. BR.AmmoType.LIGHT })
        ok(#speech == before,
            'P2 step 5: an AMMO purchase says nothing')
        ok(#props == hadProps, '...and presents nothing')
        ok(#sfx == n + 1, '...but still makes the noise a purchase makes')
    end

    -- -----------------------------------------------------------------------
    describe('D1: the tool he asked for actually moves the plate')
    -- -----------------------------------------------------------------------
    do
        ok(cmds['brgunplate'] ~= nil, 'the command exists')
        ok(cmds['brgunclerk'] ~= nil, 'and so does the clerk one (C1)')

        walkAway()
        standAt('pillbox')
        drawn = {}
        loops['gunshop.draw']()
        local was = drawn[#drawn]
        ok(was ~= nil and math.abs(was.oz - G.signUpM) < 0.001,
            'the plate draws at the config height to start with',
            was and was.oz or 'nothing drawn')

        -- A DELTA, WHICH IS THE HALF THAT MAKES IT A NUDGER. A leading sign is
        -- the whole difference between setting and moving.
        hush(cmds['brgunplate'], nil, { 'up', '-0.10' })
        hush(cmds['brgunplate'], nil, { 'fwd', '0.80' })
        drawn = {}
        loops['gunshop.draw']()
        local now = drawn[#drawn]
        ok(now ~= nil and math.abs(now.oz - (G.signUpM - 0.10)) < 0.001,
            'and the very next frame draws it 10cm lower',
            now and now.oz or 'nothing drawn')
        ok(now ~= nil and math.abs(now.oy - 0.80) < 0.001,
            '...and an unsigned number sets rather than nudges',
            now and now.oy or 'nothing drawn')

        hush(cmds['brgunplate'], nil, { 'reset' })
        drawn = {}
        loops['gunshop.draw']()
        ok(drawn[#drawn] ~= nil
            and math.abs(drawn[#drawn].oz - G.signUpM) < 0.001,
            'and reset hands it back to config')
    end

    -- -----------------------------------------------------------------------
    describe('S2: the clerk nudger starts from what the game is running')
    -- -----------------------------------------------------------------------
    do
        -- ═══ A TOOL THAT MOVED THE THING IT WAS MEASURING ═══
        --
        -- `fwd` and `face` both fell back to config; `lat` fell back to 0.0
        -- because `clerkRightM` did not exist when this command was written and
        -- C1 added it without coming back here. The config ships 1.0.
        --
        -- SO RUNNING THE TOOL UNDID THE FIX. Bare /brgunclerk moves the standing
        -- clerk to fwd/lat/face, which with lat at zero teleports him a metre
        -- off the position the game had just built him at -- and then prints
        -- `clerkRightM = 0.00` as a line to paste back into the config.
        walkAway()
        standAt('pillbox')
        local st = storeById['pillbox']
        local wx, wy = S.clerkAt(G, st, 0.0)

        local lines = grab(cmds['brgunclerk'], nil, {})
        local moved = lineWith(lines, 'pillbox')
        ok(moved ~= nil, 'the tool reports the clerk it moved',
            table.concat(lines, ' | '))

        -- NOT `moved and moved:match(...)`. `and` yields exactly ONE value, so
        -- that form silently drops the second capture and gy is nil forever.
        local gx, gy
        if moved then
            gx, gy = moved:match('now%s+([%-%d%.]+),%s*([%-%d%.]+)')
        end
        ok(gx ~= nil and gy ~= nil
            and math.abs(tonumber(gx) - wx) < 0.01
            and math.abs(tonumber(gy) - wy) < 0.01,
            'and a bare call leaves him exactly where config put him, rather '
                .. 'than sliding him off it (S2)',
            moved or 'no line')

        -- THE PASTEABLE BLOCK IS THE OTHER HALF, AND THE MORE EXPENSIVE ONE.
        -- A ped a metre out is visible; a config line the owner pastes back is
        -- a silent revert of his own playtest fix.
        local right = lineWith(lines, 'clerkRightM')
        ok(right ~= nil
            and math.abs((tonumber(right:match('=%s*([%-%d%.]+)')) or -1)
                         - (tonumber(G.clerkRightM) or 0.0)) < 0.001,
            'and the pasteable line reports the config figure, not a zero that '
                .. 'would undo C1',
            right or 'no clerkRightM line')

        -- AND IT IS STILL A NUDGER. A delta has to move from the LIVE number,
        -- which is the same fault seen from the other side: nudging from a
        -- baseline the game is not using produces a number that means nothing.
        local after = grab(cmds['brgunclerk'], nil, { 'right', '+0.25' })
        local r2 = lineWith(after, 'clerkRightM')
        ok(r2 ~= nil
            and math.abs((tonumber(r2:match('=%s*([%-%d%.]+)')) or -1)
                         - ((tonumber(G.clerkRightM) or 0.0) + 0.25)) < 0.001,
            'a +0.25 nudge moves from the config figure, not from zero',
            r2 or 'no clerkRightM line')

        hush(cmds['brgunclerk'], nil, { 'reset' })
    end
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
