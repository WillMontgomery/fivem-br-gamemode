-- Unit tests for aerial supply drops (#88).
--
-- TWO HALVES, AND BOTH LOAD THE REAL FILES.
--
--   PART A is the pure side: br_lib/config/airdrop.lua and
--   br_lib/shared/airdrop_solve.lua, plus the property that matters most and is
--   invisible in game -- that an airdrop-only item is in no world roll, proved
--   by generating a whole layout and looking.
--
--   PART B loads br_core/server/airdrop.lua itself against stubbed natives and
--   a stubbed scheduler, so the schedule, the siting decision, the phase cap and
--   the auto-open are exercised as code rather than as a description of code.
--
-- WHAT THIS CANNOT TELL YOU. There is no FiveM here. Whether `p_cargo_chute_s`
-- renders, whether a crate at 260m above a hillside probes to the right ground
-- height, and whether blip 161 looks like anything useful are questions only a
-- playtest answers.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_airdrop.lua

local realPrint = print
local realExit  = os.exit

-- clock.lua reaches for GetGameTimer at load; the server harness below drives
-- it properly.
local gameMs = 1000
function GetGameTimer() return gameMs end

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            realExit(1)
        end
        chunk()
    end
end

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    -- The load order under test: AFTER loot.lua, which is what keeps the
    -- airdrop-only items out of every bucket loot.lua has already built.
    'br_lib/config/airdrop.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/loot_gen.lua',
    'br_lib/shared/airdrop_solve.lua',
})

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-6)
end

local A = BR.Config.Airdrop

-- =========================================================================
-- PART A -- config
-- =========================================================================

describe('config: the owner\'s numbers')
do
    eq(A.perMatch, 1, 'exactly one airdrop per match')
    eq(A.chance, 1.0, 'and it happens, by default')
    eq(A.insideBy, 250.0, 'the landing point is 250m inside the circle')
    eq(A.maxPhase, 4, 'no airdrops past storm stage 4')
    eq(A.blipSprite, 161, 'blip type 161')
    eq(A.blipLingerMs, 60000, 'the blip outlives the landing by one minute')
    eq(#A.payout, 12, 'up to 12 items')

    -- VERBATIM. The owner gave this sentence character for character
    -- (2026-08-21) and the only way it stays that way is a literal here that
    -- has to be edited on purpose.
    eq(A.notifyText,
       'An airdrop is arriving! It brings ultra-rare loot - first come, first served.',
       'the notification is the owner\'s wording, exactly')

    -- Below 1.0 must be ALLOWED as a probability -- so nothing may clamp or
    -- floor it. Read as a plain number by BR.Airdrop.begin.
    ok(type(A.chance) == 'number' and A.chance <= 1.0,
        'chance is a plain number, so a value below 1.0 is meaningful')
end

describe('config: props')
do
    -- The existing pair, still a pair. If the crate ever stops being
    -- airdroppable both of these move together -- an open crate husk beside a
    -- differently-styled sealed one is exactly what the owner ruled out.
    eq(A.crateProp, BR.Config.Loot.chestProp,
        'the airdrop crate is the crate we already use')
    eq(A.huskProp, BR.Config.Loot.chestOpenProp,
        'and its husk is the husk we already use -- the pair stays matched')

    -- The CARGO canopy, which is not the player's canopy. Getting these two
    -- confused is the single most likely way to ship an airdrop wearing a
    -- backpack chute.
    ok(A.chuteModel ~= BR.Config.Drop.parachuteModel,
        'the crate canopy is not the player canopy')
    eq(A.chuteModel, 'p_cargo_chute_s', 'it is Rockstar\'s own cargo chute')

    -- The flares (owner, 2026-08-21). Two things have to be true for the smoke
    -- to exist at all, and both are one config line, so both are worth pinning:
    -- a prop to hang the emitter on, and an asset the emitter comes out of.
    ok(type(A.flareProp) == 'string' and A.flareProp ~= '',
        'the flares have a prop')
    ok(type(A.flarePtfxAsset) == 'string' and A.flarePtfxAsset ~= '',
        'and a particle asset to stream')
    ok(type(A.flarePtfxName) == 'string' and A.flarePtfxName ~= '',
        'and an effect inside it')
    ok(A.flareOffset and (A.flareOffset.x or 0.0) > 0.0,
        'and an offset with a positive x -- the sign is what makes it two sides')
end

describe('config: exclusive loot is exclusive')
do
    -- THE OWNER'S LIST, and it is weapons now rather than a consumable: "Things
    -- like explosives, RPGs, miniguns, etc are exciting." The Heavy Shield that
    -- used to be the exclusive item is gone entirely ("We don't need heavy
    -- shield to exist"), which is why this block no longer mentions it and why
    -- nothing named `heavyshield` may resolve anywhere.
    ok(BR.Config.ConsumableById.heavyshield == nil,
        'the Heavy Shield does not resolve by id -- it is gone, not disabled')
    for _, c in ipairs(BR.Config.Consumables) do
        ok(c.id ~= 'heavyshield', 'and it is in no consumable list')
    end
    ok(BR.Config.AirdropItems == nil,
        'and the array that existed only to register it is gone with it')

    ok(#BR.Config.AirdropWeapons >= 4, 'there are airdrop-only weapons')

    for _, w in ipairs(BR.Config.AirdropWeapons) do
        ok(BR.Config.WeaponById[w.id] == w,
            ('%s resolves by id, so a pool can name it and the inventory can '
             .. 'hold it'):format(w.id))
        ok(BR.Config.WeaponByHash[BR.NormHash(w.hash)] == w,
            ('%s resolves by hash, so the validator can price a hit with it')
                :format(w.id))
        ok(BR.Config.IsAllowedWeapon(w.hash),
            ('%s is on the allowlist -- the airdrop issues it'):format(w.id))

        -- ...and in NO bucket, because a bucket is the only thing
        -- BR.RollLootStack ever rolls against. This is the whole of "found
        -- nowhere else".
        local bucketed = false
        for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
            for _, x in ipairs(BR.Config.WeaponsByRarity[r] or {}) do
                if x.id == w.id then bucketed = true end
            end
        end
        ok(not bucketed,
            ('%s is in no rarity bucket, so no world roll can produce it')
                :format(w.id))
    end

    -- AND THE BUCKETS DID NOT MOVE. Registering four weapons into the id
    -- lookups must not change the size of any bucket, or the legendary tier of
    -- every crate on the map has quietly changed.
    local counted = 0
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        counted = counted + #BR.Config.WeaponsByRarity[r]
    end
    eq(counted, #BR.Config.Weapons,
        'the rarity buckets still hold exactly BR.Config.Weapons and nothing else')
end

describe('config: pools resolve')
do
    for _, name in ipairs(A.payout) do
        local pool = A.resolvedPools[name]
        ok(pool ~= nil and #pool > 0,
            ('payout slot "%s" resolves to a non-empty pool'):format(name),
            pool and #pool or 'nil')
    end

    -- The legendary pool tracks the weapon table rather than a hand-typed list,
    -- which is the point of naming a bucket instead of ids.
    eq(#A.resolvedPools.legendary,
       #BR.Config.WeaponsByRarity[BR.Rarity.LEGENDARY],
       'the legendary pool is the legendary bucket')

    -- THE EXCLUSIVE POOL IS THE EXPLOSIVES, whole. Named by id rather than by
    -- bucket, so this is also the check that nobody quietly re-pointed it at a
    -- tier -- which would pay out ordinary rifles under an "exclusive" label.
    eq(#A.resolvedPools.exclusive, #BR.Config.AirdropWeapons,
        'the exclusive pool is the whole airdrop shelf')
    for _, t in ipairs(A.resolvedPools.exclusive) do
        eq(t.kind, BR.ItemKind.WEAPON, ('%s is dealt as a weapon'):format(t.item))
        ok(BR.Config.WeaponById[t.item] ~= nil,
            ('%s resolves'):format(t.item))
    end

    -- THE #191 SEAM. `cprkit` is named in the healing pool and does not exist
    -- yet, so it is dropped at resolution. The day it is registered this test
    -- changes and nothing else does.
    local hasCpr = false
    for _, t in ipairs(A.resolvedPools.healing) do
        if t.item == 'cprkit' then hasCpr = true end
    end
    if BR.Config.ConsumableById.cprkit then
        ok(hasCpr, 'cprkit exists, so it is in the healing pool')
    else
        ok(not hasCpr,
            'cprkit does not exist yet, so the seam resolves to nothing rather '
            .. 'than to a nil item')
    end

    -- Every template is a usable stack. A pool entry missing `kind` produces a
    -- ground entry the client cannot draw and the inventory cannot take.
    for name, pool in pairs(A.resolvedPools) do
        local shaped = true
        for _, t in ipairs(pool) do
            if type(t.item) ~= 'string' or type(t.kind) ~= 'string'
               or type(t.rarity) ~= 'number' or type(t.count) ~= 'number' then
                shaped = false
            end
        end
        ok(shaped, ('every template in pool "%s" is a complete stack'):format(name))
    end
end

describe('config: the Volts pile')
do
    -- The owner named the number: "they should be 100 Volts".
    eq(A.voltsAmount, 100, 'a drop carries 100 Volts')

    local pool = A.resolvedPools.volts
    ok(pool ~= nil and #pool == 1,
        'the pool is one card, because there is one thing it can pay',
        pool and #pool or 'nil')

    local t = pool[1]
    eq(t.kind, 'volts',
        'it is its own loot kind -- BR.ItemKind names what a SLOT can hold, and '
        .. 'this never reaches one')
    eq(t.count, A.voltsAmount, 'and the count IS the amount')
    ok(type(t.prop) == 'string' and t.prop ~= '',
        'it names its own prop -- there is no id table to resolve one from')

    -- IT IS IN THE PAYOUT, ONCE. A drop that carried no Volts would still pass
    -- every other test in this file.
    local slots = 0
    for _, name in ipairs(A.payout) do
        if name == 'volts' then slots = slots + 1 end
    end
    eq(slots, 1, 'exactly one payout slot draws from it')

    -- AND IT IS NOT AN INVENTORY ITEM ANYWHERE. The owner: "This should be an
    -- item that does not go into inventory."
    ok(BR.Config.ConsumableById.volts == nil, 'volts is not a consumable')
    ok(BR.Config.WeaponById.volts == nil, 'volts is not a weapon')
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        for _, x in ipairs(BR.Config.ConsumablesByRarity[r] or {}) do
            ok(x.id ~= 'volts', 'and no bucket can roll one')
        end
    end

    -- The label the pickup prompt shows. "100 Volts", not "Volts x100".
    eq(BR.LootLabel({ kind = 'volts', item = 'volts', count = 100 }),
       '100 Volts', 'the count is the name')
end

describe('config: the world layout is untouched')
do
    -- THE PROPERTY THAT CANNOT BE SEEN IN GAME. Registering four weapons into
    -- the id lookups and into no bucket is correct and subtle, and the failure
    -- mode -- an RPG in an ordinary crate -- is one crate in hundreds, on a map
    -- that rolls ~1900 stacks. So generate a whole match's layout and look.
    local exclusive = { volts = true }
    for _, w in ipairs(BR.Config.AirdropWeapons) do exclusive[w.id] = true end

    local entries = BR.BuildLootLayout(20260821)
    local leaked, items = nil, 0
    for _, e in ipairs(entries) do
        items = items + 1
        if exclusive[e.item] then leaked = e.item end
        for _, s in ipairs(e.contents or {}) do
            items = items + 1
            if exclusive[s.item] then leaked = s.item end
        end
    end

    ok(items > 1000, 'the layout is a real one', items)
    ok(leaked == nil,
        'no airdrop-only item appears anywhere in a whole match layout', leaked)
end

-- =========================================================================
-- PART A -- siting
-- =========================================================================

describe('siting: the 250m margin')
do
    local pois = {
        { id = 'centre', x =    0.0, y = 0.0, z = 0.0 },
        { id = 'edge',   x =  750.0, y = 0.0, z = 0.0 },   -- exactly r - margin
        { id = 'just',   x =  750.1, y = 0.0, z = 0.0 },   -- a hair outside
        { id = 'far',    x = 5000.0, y = 0.0, z = 0.0 },
    }

    local got = BR.AirdropSites(pois, 0.0, 0.0, 1000.0, 250.0, nil)
    eq(#got, 2, 'two POIs are at least 250m inside a 1000m circle')
    eq(got[1].id, 'centre', 'and they come back in authored order')
    eq(got[2].id, 'edge', 'a POI exactly on the margin qualifies')

    local ids = {}
    for _, p in ipairs(got) do ids[p.id] = true end
    ok(not ids.just, 'a POI a tenth of a metre outside the margin does not')
    ok(not ids.far, 'and neither does one outside the circle entirely')
end

describe('siting: no candidate is a real answer')
do
    local pois = { { id = 'a', x = 400.0, y = 0.0, z = 0.0 } }

    -- Phase 5's circle is 260m across the radius. A 250m margin leaves 10m,
    -- which is the conflict the owner's two rules produce and the reason this
    -- returns a list rather than a POI.
    eq(#BR.AirdropSites(pois, 0.0, 0.0, 260.0, 250.0, nil), 0,
        'a late circle has no POI 250m inside it')

    -- And the degenerate case: a margin wider than the circle.
    eq(#BR.AirdropSites(pois, 0.0, 0.0, 100.0, 250.0, nil), 0,
        'a circle smaller than the margin has no sites at all')

    -- THE TIGHTEST CIRCLE THAT STILL HAS AN ANSWER. A POI standing exactly on
    -- the centre of a circle whose radius IS the margin is exactly `margin`
    -- inside it, so it qualifies -- the same inclusive rule as the boundary
    -- case above, and the reason there is no early return for reach <= 0.
    local centred = { { id = 'bullseye', x = 0.0, y = 0.0, z = 0.0 } }
    eq(#BR.AirdropSites(centred, 0.0, 0.0, 250.0, 250.0, nil), 1,
        'a POI on the centre of a 250m circle is exactly 250m inside it')
    eq(#BR.AirdropSites(centred, 0.0, 0.0, 249.999, 250.0, nil), 0,
        'and a hair under that, it is not')

    -- NOTHING IS BENT. The candidate list never contains a POI that fails the
    -- rule, however empty it would otherwise be.
    local far = { { id = 'only', x = 900.0, y = 0.0, z = 0.0 } }
    eq(#BR.AirdropSites(far, 0.0, 0.0, 1000.0, 250.0, nil), 0,
        'the only POI in range is not offered when it fails the margin')
end

describe('siting: water and no-loot zones')
do
    local pois = {
        { id = 'dry', x = 0.0, y = 0.0, z = 0.0 },
        { id = 'wet', x = 100.0, y = 0.0, z = 0.0 },
    }
    local got = BR.AirdropSites(pois, 0.0, 0.0, 1000.0, 250.0,
        function(x) return x < 50.0 end)
    eq(#got, 1, 'the placeable predicate is applied')
    eq(got[1].id, 'dry', 'and it is the one that passed')
end

describe('siting: picking')
do
    local pois = {}
    for i = 1, 20 do
        pois[i] = { id = 'p' .. i, x = i * 10.0, y = 0.0, z = 0.0 }
    end

    local a = BR.AirdropPickSite(BR.Rng(99), pois, 0.0, 0.0, 5000.0, 250.0, nil)
    local b = BR.AirdropPickSite(BR.Rng(99), pois, 0.0, 0.0, 5000.0, 250.0, nil)
    ok(a ~= nil and a == b, 'the same seed picks the same POI')

    local _, n = BR.AirdropPickSite(BR.Rng(1), pois, 0.0, 0.0, 5000.0, 250.0, nil)
    eq(n, 20, 'and it reports how many qualified')

    -- A FAILED CHECK MUST BURN NO RNG. The server re-asks this every few
    -- seconds while a circle shrinks; if a miss consumed a draw, the payout a
    -- match eventually gets would depend on how many times the question was
    -- asked -- which is exactly the class of bug the per-subsystem RNG streams
    -- exist to prevent.
    local probe = BR.Rng(4242)
    local before = probe:float()
    local rng = BR.Rng(4242)
    rng:float()
    for _ = 1, 25 do
        local p = BR.AirdropPickSite(rng, pois, 0.0, 0.0, 100.0, 250.0, nil)
        ok(p == nil, 'a hopeless circle yields nothing')
    end
    local after = rng:float()
    local probe2 = BR.Rng(4242)
    probe2:float()
    eq(after, probe2:float(),
        'and twenty-five failed checks advanced the stream by nothing')
    local _ = before
end

describe('siting: against the real map')
do
    local lsia = BR.Config.Map.GetPOI('lsia')
    ok(lsia ~= nil, 'the real POI table is loaded')

    -- A phase-2-sized circle centred on a real POI: that POI is certainly
    -- 250m inside it, and everything returned is.
    local got = BR.AirdropSites(BR.Config.Map.POIs, lsia.x, lsia.y, 1600.0,
        A.insideBy, BR.LootPlaceable)
    ok(#got > 0, 'a mid-game circle over the city has candidates', #got)

    local allInside = true
    for _, p in ipairs(got) do
        if BR.Dist(p.x, p.y, lsia.x, lsia.y) > 1600.0 - A.insideBy then
            allInside = false
        end
    end
    ok(allInside, 'and every one of them is at least 250m inside')
end

describe('siting: the storm phase cap')
do
    ok(not BR.AirdropStormOk(nil, 4), 'no storm record, no drop')
    ok(BR.AirdropStormOk({ phase = 1 }, 4), 'phase 1 is fine')
    ok(BR.AirdropStormOk({ phase = 4 }, 4), 'phase 4 is fine -- "past 4" is 5')
    ok(not BR.AirdropStormOk({ phase = 5 }, 4), 'phase 5 is past the cap')
    ok(not BR.AirdropStormOk({ phase = 8 }, 4), 'and so is the last phase')
end

-- =========================================================================
-- PART A -- the payout
-- =========================================================================

describe('payout')
do
    local items = BR.AirdropPayout(BR.Rng(7), A)
    eq(#items, #A.payout, 'one item per payout slot')

    local shaped = true
    for _, s in ipairs(items) do
        if type(s.item) ~= 'string' or type(s.kind) ~= 'string'
           or type(s.rarity) ~= 'number' or type(s.count) ~= 'number' then
            shaped = false
        end
    end
    ok(shaped, 'every stack is complete enough to be a ground entry')

    -- Deterministic for a seed, which is the same contract the loot layout has.
    local again = BR.AirdropPayout(BR.Rng(7), A)
    local same = true
    for i = 1, #items do
        if items[i].item ~= again[i].item or items[i].count ~= again[i].count then
            same = false
        end
    end
    ok(same, 'the same seed rolls the same drop')

    -- Different seeds should not roll the same twelve items in the same order.
    local other = BR.AirdropPayout(BR.Rng(8), A)
    local differs = false
    for i = 1, #items do
        if items[i].item ~= other[i].item then differs = true end
    end
    ok(differs, 'a different seed rolls a different drop')

    -- SHUFFLE AND DEAL, so a pool bigger than the slots pointing at it never
    -- repeats. Three legendary slots against a four-weapon pool must be three
    -- DIFFERENT legendaries.
    local legendary = {}
    for _, s in ipairs(items) do
        for _, t in ipairs(A.resolvedPools.legendary) do
            if s.item == t.item then legendary[s.item] = (legendary[s.item] or 0) + 1 end
        end
    end
    local dupes = 0
    for _, n in pairs(legendary) do if n > 1 then dupes = dupes + 1 end end
    eq(dupes, 0, 'no legendary weapon appears twice in one drop')

    -- Firearms arrive loaded, the way every other weapon entry does.
    local guns, loaded = 0, 0
    for _, s in ipairs(items) do
        if s.kind == BR.ItemKind.WEAPON then
            guns = guns + 1
            if s.clip and s.clip > 0 then loaded = loaded + 1 end
        end
    end
    ok(guns > 0, 'a drop contains firearms', guns)
    eq(loaded, guns, 'and every one of them carries a magazine')

    -- COPIES, NEVER THE TEMPLATE. These become ground entries the inventory
    -- then mutates; handing out the shared template would let one pickup
    -- rewrite what every future drop contains.
    local first = BR.AirdropPayout(BR.Rng(11), A)
    first[1].count = 99999
    local second = BR.AirdropPayout(BR.Rng(11), A)
    ok(second[1].count ~= 99999,
        'mutating one drop\'s stack does not reach into the next')
end

describe('payout: it actually contains the exclusive loot')
do
    -- The owner's requirement in one assertion. A payout table that has drifted
    -- to all guns and ammo would still be twelve valid items, still
    -- deterministic, and would have quietly deleted the whole point of #88.
    local excl = {}
    for _, w in ipairs(BR.Config.AirdropWeapons) do excl[w.id] = true end

    local drops, withExplosive, withVolts, voltsTotal = 0, 0, 0, 0
    for seed = 1, 20 do
        drops = drops + 1
        local sawExpl, sawVolts = false, 0
        for _, s in ipairs(BR.AirdropPayout(BR.Rng(seed), A)) do
            if excl[s.item] then sawExpl = true end
            if s.kind == 'volts' then
                sawVolts = sawVolts + 1
                voltsTotal = voltsTotal + s.count
            end
        end
        if sawExpl then withExplosive = withExplosive + 1 end
        if sawVolts == 1 then withVolts = withVolts + 1 end
    end

    eq(withExplosive, drops,
        'every drop carries a weapon that is found nowhere else')
    eq(withVolts, drops, 'and exactly one Volts pile')
    eq(voltsTotal, drops * A.voltsAmount,
        'each one worth exactly the configured amount')

    -- TWO EXCLUSIVE SLOTS AGAINST A FOUR-WEAPON POOL, so they are two DIFFERENT
    -- explosives rather than the same RPG twice -- the whole reason the payout
    -- shuffles and deals instead of drawing with replacement.
    local seen = {}
    for _, s in ipairs(BR.AirdropPayout(BR.Rng(4), A)) do
        if excl[s.item] then seen[s.item] = (seen[s.item] or 0) + 1 end
    end
    local n, repeats = 0, 0
    for _, c in pairs(seen) do
        n = n + 1
        if c > 1 then repeats = repeats + 1 end
    end
    eq(n, 2, 'two exclusive slots pay two explosives')
    eq(repeats, 0, 'and they are different ones')
end

describe('payout: a short pool wraps rather than paying nothing')
do
    -- Two `exclusive` slots against a one-item pool (which is what it is until
    -- #191 lands). Wrapping is what stops those slots silently paying nothing.
    local cfg = {
        payout = { 'p', 'p', 'p' },
        resolvedPools = {
            p = { { item = 'only', kind = 'consumable', rarity = 5, count = 1 } },
        },
    }
    local out = BR.AirdropPayout(BR.Rng(3), cfg)
    eq(#out, 3, 'three slots, three items')
    eq(out[3].item, 'only', 'the one-item pool is dealt again rather than skipped')
end

describe('payout: a missing pool is skipped, not crashed into')
do
    local cfg = { payout = { 'nope' }, resolvedPools = {} }
    local out = BR.AirdropPayout(BR.Rng(3), cfg)
    eq(#out, 0, 'a payout naming a pool that does not exist yields nothing')
end

-- =========================================================================
-- PART A -- the descent
-- =========================================================================

describe('descent')
do
    local poi = { id = 'x', x = 10.0, y = 20.0, z = 30.0 }
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 45.0)

    eq(rec.x, 10.0, 'the record carries the POI\'s own x')
    eq(rec.y, 20.0, 'and its y')
    eq(rec.gz, 30.0, 'and its authored height as the ground hint')
    eq(rec.poi, 'x', 'and its id, for the logs')
    eq(rec.alt, 260.0, 'and the altitude it starts from')

    ok(near(BR.AirdropProgress(rec, 1000.0), 0.0), 'progress is 0 at tStart')
    ok(near(BR.AirdropProgress(rec, 16000.0), 0.5), 'and 0.5 halfway')
    ok(near(BR.AirdropProgress(rec, 31000.0), 1.0), 'and 1 at tLand')
    ok(near(BR.AirdropProgress(rec, 0.0), 0.0), 'clamped below')
    ok(near(BR.AirdropProgress(rec, 99999.0), 1.0), 'and above')

    ok(near(BR.AirdropHeightAt(rec, 1000.0), 260.0), 'it starts 260m up')
    ok(near(BR.AirdropHeightAt(rec, 16000.0), 130.0), 'and is halfway down halfway')
    ok(near(BR.AirdropHeightAt(rec, 31000.0), 0.0), 'and on the ground at tLand')

    ok(not BR.AirdropLanded(rec, 30999.0), 'not landed a millisecond early')
    ok(BR.AirdropLanded(rec, 31000.0), 'landed at tLand')

    -- A zero-length descent (reachable only from the dev command) must resolve
    -- rather than divide by zero.
    local instant = BR.BuildAirdropRecord(1, poi, 260.0, 5000.0, 5000.0, 0.0)
    ok(near(BR.AirdropProgress(instant, 5000.0), 1.0),
        'a zero-span descent is already over')
end

describe('descent: the rigid parts')
do
    -- THE CANOPY AND THE FLARES ARE NOT ATTACHED TO THE CRATE. They are solved
    -- from the same record, so a test can ask where they are -- which an
    -- ATTACH_ENTITY_TO_ENTITY could not be asked outside a running client, and
    -- is the reason this design was chosen over Rockstar's.
    local poi = { id = 'x', x = 100.0, y = 200.0, z = 0.0 }
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 30000.0, 0.0)

    ok(near(BR.AirdropHeadingAt(rec, 0.0, 30.0), 0.0),
        'the crate starts on its resting heading')
    ok(near(BR.AirdropHeadingAt(rec, 15000.0, 30.0), 15.0),
        'and has turned half the spin halfway down')
    ok(near(BR.AirdropHeadingAt(rec, 30000.0, 30.0), 30.0),
        'and the whole of it by touchdown')
    ok(near(BR.AirdropHeadingAt(rec, 30000.0, 0.0), 0.0),
        'a zero spin does not turn it at all')

    -- HEADING 0 IS NORTH AND FORWARD IS +Y, which is the half of GTA's
    -- convention that is easy to get backwards -- and getting it backwards puts
    -- both flares on the same side of the crate, which nothing else here would
    -- notice.
    local rx, ry = BR.AirdropOffsetAt(rec, 0.0, 1.0, 0.0, 0.0)
    ok(near(rx, 101.0) and near(ry, 200.0),
        'facing north, the crate\'s right is +X (east)',
        ('%.3f, %.3f'):format(rx, ry))
    local fx, fy = BR.AirdropOffsetAt(rec, 0.0, 0.0, 1.0, 0.0)
    ok(near(fx, 100.0) and near(fy, 201.0),
        'and its forward is +Y (north)', ('%.3f, %.3f'):format(fx, fy))

    -- Quarter turn: heading grows anticlockwise, so at 90 the right hand points
    -- north.
    local turned = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 30000.0, 90.0)
    local qx, qy = BR.AirdropOffsetAt(turned, 0.0, 1.0, 0.0, 0.0)
    ok(near(qx, 100.0, 1e-9) and near(qy, 201.0, 1e-9),
        'facing west, the crate\'s right is north',
        ('%.6f, %.6f'):format(qx, qy))

    -- ...AND FORWARD AT THAT HEADING, WHICH IS THE HALF EVERY CHECK ABOVE
    -- MISSES. Each of them sits at a heading where one of sin/cos is zero and
    -- uses an offset with one component, so a sign error in the OTHER term
    -- multiplies by nothing and cannot show -- a mutation pass proved exactly
    -- that by flipping it and surviving. Both the config's offsets happen to
    -- have y = 0 today, so nothing in the game would notice either, until the
    -- day somebody moves a flare forward.
    local wx, wy = BR.AirdropOffsetAt(turned, 0.0, 0.0, 1.0, 0.0)
    ok(near(wx, 99.0, 1e-9) and near(wy, 200.0, 1e-9),
        'facing west, one metre forward is one metre west',
        ('%.6f, %.6f'):format(wx, wy))

    -- And a diagonal with both components set, where all four terms of the
    -- matrix are alive at once.
    local diag = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 30000.0, 45.0)
    local dx, dy = BR.AirdropOffsetAt(diag, 0.0, 1.0, 1.0, 0.0)
    local h = math.sqrt(2.0) * 0.5
    ok(near(dx, 100.0 + h - h, 1e-9) and near(dy, 200.0 + h + h, 1e-9),
        'a diagonal offset at a diagonal heading resolves both axes',
        ('%.6f, %.6f'):format(dx, dy))

    -- THE TWO FLARES ARE ON OPPOSITE SIDES, AT EVERY MOMENT OF THE FALL. This
    -- is the property the sign flip in the client exists for, and it has to
    -- survive the spin -- an offset rotated by a heading computed somewhere else
    -- would drift the two apart.
    local off = A.flareOffset.x
    for _, t in ipairs({ 0.0, 7500.0, 15000.0, 30000.0 }) do
        local lx, ly = BR.AirdropOffsetAt(rec, t,  off, 0.0, A.spinDegrees)
        local mx, my = BR.AirdropOffsetAt(rec, t, -off, 0.0, A.spinDegrees)
        ok(near(BR.Dist(lx, ly, mx, my), off * 2.0, 1e-6),
            ('the flares stay %.1fm apart at t=%d'):format(off * 2.0, t))
        -- ...and the crate is exactly between them.
        ok(near((lx + mx) * 0.5, rec.x, 1e-6)
           and near((ly + my) * 0.5, rec.y, 1e-6),
            ('and the crate is midway between them at t=%d'):format(t))
    end

    -- A zero offset is the crate's own position, whatever the heading.
    local zx, zy = BR.AirdropOffsetAt(rec, 12345.0, 0.0, 0.0, 137.0)
    ok(near(zx, rec.x) and near(zy, rec.y),
        'a zero offset never leaves the crate')

    ok(select(1, BR.AirdropOffsetAt(nil, 0.0, 1.0, 1.0, 30.0)) == 0.0,
        'no record, no position')
end

describe('descent: the blip window')
do
    local poi = { id = 'x', x = 0.0, y = 0.0, z = 0.0 }
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)

    ok(not BR.AirdropBlipVisible(rec, 999.0, 60000),
        'nothing on the map before the drop is announced')
    ok(BR.AirdropBlipVisible(rec, 1000.0, 60000), 'up the moment it is announced')
    ok(BR.AirdropBlipVisible(rec, 31000.0, 60000), 'still up as it lands')
    ok(BR.AirdropBlipVisible(rec, 91000.0, 60000),
        'still up exactly one minute after landing')
    ok(not BR.AirdropBlipVisible(rec, 91001.0, 60000),
        'and gone a millisecond later')
    ok(not BR.AirdropBlipVisible(nil, 5000.0, 60000), 'no record, no blip')
end

describe('the plane')
do
    -- The owner said no plane and then changed their mind. What it bought is
    -- the RELEASE: a window between the announcement and the crate leaving the
    -- aircraft, so a match that has just been told an airdrop is coming can look
    -- up and watch it arrive rather than watch it already leaving.
    local poi = { id = 'x', x = 1000.0, y = 2000.0, z = 30.0 }
    -- Announced at 0, released at 10s, on the ground at 40s. Facing NORTH, so
    -- the flight path runs up +Y and the arithmetic is readable.
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 40000.0, 0.0, 10000.0)
    local cfg = { planeSpeed = 100.0, planeAltAbove = 40.0, planeTrailMs = 15000 }

    eq(rec.tRelease, 10000.0, 'the record carries a release time of its own')

    -- THE FALL IS MEASURED FROM THE RELEASE, not from the announcement. A
    -- progress that still counted from tStart would have the crate a quarter of
    -- the way down at the moment it left the plane.
    ok(near(BR.AirdropProgress(rec, 10000.0), 0.0), 'progress is 0 at the release')
    ok(near(BR.AirdropProgress(rec, 25000.0), 0.5), 'and 0.5 halfway down')
    ok(near(BR.AirdropProgress(rec, 40000.0), 1.0), 'and 1 on the ground')
    ok(near(BR.AirdropHeightAt(rec, 10000.0), 260.0),
        'and it is still at full altitude when it leaves')
    ok(near(BR.AirdropHeightAt(rec, 0.0), 260.0),
        'as it is during the whole run-in')

    ok(not BR.AirdropReleased(rec, 9999.0), 'the crate is aboard until the release')
    ok(BR.AirdropReleased(rec, 10000.0), 'and away at it')
    ok(not BR.AirdropReleased(nil, 0.0), 'no record, nothing released')

    -- WHERE IT IS. Over the drop point exactly at the release, inbound before,
    -- outbound after -- one straight line at one speed, which is what makes it a
    -- pure function of the record with nothing on the wire.
    local ax, ay, az, ah = BR.AirdropPlaneAt(rec, 10000.0, cfg)
    ok(near(ax, rec.x, 1e-6) and near(ay, rec.y, 1e-6),
        'the plane is exactly over the drop point at the release',
        ('%.3f, %.3f'):format(ax, ay))
    ok(near(az, 260.0 + 40.0), 'flying above the crate\'s release altitude', az)
    ok(near(ah, rec.heading), 'on the record\'s own bearing')

    -- Ten seconds earlier, a kilometre back down the approach: heading 0 is
    -- north, so inbound is from the SOUTH.
    local bx, by = BR.AirdropPlaneAt(rec, 0.0, cfg)
    ok(near(bx, rec.x, 1e-6) and near(by, rec.y - 1000.0, 1e-6),
        'ten seconds before, it is a kilometre south -- inbound, not outbound',
        ('%.3f, %.3f'):format(bx, by))

    -- ...and after, the same distance the other way.
    local cx2, cy2 = BR.AirdropPlaneAt(rec, 20000.0, cfg)
    ok(near(cx2, rec.x, 1e-6) and near(cy2, rec.y + 1000.0, 1e-6),
        'and ten seconds later, a kilometre north', ('%.3f, %.3f'):format(cx2, cy2))

    -- The bearing is not ignored: due west should run the path along -X.
    local west = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 40000.0, 90.0, 10000.0)
    local wx, wy = BR.AirdropPlaneAt(west, 20000.0, cfg)
    ok(near(wx, rec.x - 1000.0, 1e-6) and near(wy, rec.y, 1e-6),
        'a plane on heading 90 leaves to the west', ('%.3f, %.3f'):format(wx, wy))

    -- WHEN IT IS THERE. From the announcement to trailMs past the release, and
    -- NOT for the whole descent: the aircraft's job ends when the box leaves it.
    ok(not BR.AirdropPlaneVisible(rec, -1.0, cfg), 'nothing before the announcement')
    ok(BR.AirdropPlaneVisible(rec, 0.0, cfg), 'in the air from the announcement')
    ok(BR.AirdropPlaneVisible(rec, 10000.0, cfg), 'and at the release')
    ok(BR.AirdropPlaneVisible(rec, 25000.0, cfg),
        'and for the trail window afterwards')
    ok(not BR.AirdropPlaneVisible(rec, 25001.0, cfg), 'and gone after it')
    ok(not BR.AirdropPlaneVisible(nil, 0.0, cfg), 'no record, no plane')
    ok(rec.tLand > 10000.0 + (cfg.planeTrailMs or 0),
        'the plane is gone well before the crate lands, by construction')

    -- A RECORD WITH NO RELEASE IS THE OLD ONE, and must still describe a crate
    -- that starts falling when it is announced. Nothing builds one today; this
    -- is what stops the default being a surprise.
    local old = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 30000.0, 0.0)
    eq(old.tRelease, old.tStart, 'tRelease defaults to tStart')
    ok(near(BR.AirdropProgress(old, 15000.0), 0.5),
        'and such a record falls exactly as it always did')
end

describe('descent: expiry is not the same question as visibility')
do
    -- THE 2026-08-22 PLAYTEST BUG, as arithmetic. "Should the blip be up" is
    -- false at BOTH ends of the window; "is this drop over" is only ever true at
    -- the far one. The client used to tear a drop down on the first predicate,
    -- so a clock estimate a few tens of milliseconds behind the server's
    -- destroyed the whole airdrop on the frame it arrived.
    local poi = { id = 'x', x = 0.0, y = 0.0, z = 0.0 }
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)

    ok(not BR.AirdropBlipVisible(rec, 900.0, 60000),
        'a record from the future is not visible yet...')
    ok(not BR.AirdropExpired(rec, 900.0, 60000),
        '...and is emphatically not over -- this is the pair that used to be '
        .. 'one question')

    ok(not BR.AirdropExpired(rec, 1000.0, 60000), 'not over at tStart')
    ok(not BR.AirdropExpired(rec, 31000.0, 60000), 'not over as it lands')
    ok(not BR.AirdropExpired(rec, 91000.0, 60000),
        'not over exactly one minute after landing')
    ok(BR.AirdropExpired(rec, 91001.0, 60000), 'over a millisecond later')
    ok(BR.AirdropExpired(nil, 0.0, 60000), 'and no record is nothing to draw')

    -- A YEAR EARLY IS STILL NOT OVER. There is no lower bound at all, which is
    -- the whole point: however far behind a client's clock estimate is, the
    -- answer is "wait", never "throw it away".
    ok(not BR.AirdropExpired(rec, -1e9, 60000),
        'no amount of clock skew in that direction expires a drop')
end

-- =========================================================================
-- PART B -- the server
-- =========================================================================

-- Stubs. Everything the real br_core/server/airdrop.lua reaches for, and
-- nothing else -- a stub of BR.StormAt or BR.AirdropPickSite would make this
-- suite agree with itself rather than with the code.

local jobs      = {}     -- [name] = fn, so a test can step the tick by hand
local commands  = {}     -- [name] = fn
local published = {}     -- every BR.Broadcast.toMatch
local notices   = {}     -- every BR.Server.notify
local spawned   = {}     -- every BR.Loot.spawnStack
local logs      = {}

function print(s) logs[#logs + 1] = tostring(s) end

BR.Sched = {
    every = function(_, name, fn) jobs[name] = fn end,
}

function RegisterCommand(name, fn) commands[name] = fn end

local matches = {}

BR.Server = {
    eachMatch = function(fn)
        for _, m in ipairs(matches) do fn(m) end
    end,
    audience = function(m) return { m.id * 100 + 1, m.id * 100 + 2 } end,
    notify = function(target, text, tone)
        notices[#notices + 1] = { target = target, text = text, tone = tone }
    end,
    latestMatch = function() return matches[#matches] end,
}

BR.Broadcast = {
    toMatch = function(m, event, payload)
        published[#published + 1] = { m = m, event = event, payload = payload }
    end,
}

BR.Loot = {
    spawnStack = function(m, stack, x, y, z, from)
        spawned[#spawned + 1] =
            { m = m, stack = stack, x = x, y = y, z = z, from = from }
        return stack
    end,
}

loadAll({ 'br_core/server/airdrop.lua' })

--- A match with a live storm centred on a real POI, big enough that plenty of
--- POIs qualify.
--- @param id integer
--- @param radius number|nil
--- @param phase integer|nil
local function newMatch(id, radius, phase)
    local poi = BR.Config.Map.GetPOI('lsia')
    local r = radius or 2600.0
    local m = {
        id = id,
        state = BR.MatchState.PLAYING,
        loot = { items = {} },
        -- A HELD circle, so BR.StormAt answers the same thing whatever the
        -- clock is doing: the tests here are about the airdrop, not about the
        -- storm's own interpolation.
        storm = BR.BuildStormRecord(phase or 1, poi.x, poi.y, r,
            poi.x, poi.y, r, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0),
    }
    matches[#matches + 1] = m
    return m
end

local function reset()
    matches = {}
    published, notices, spawned, logs = {}, {}, {}, {}
    gameMs = gameMs + 10000000
end

local function tick() jobs['airdrop.tick']() end

--- ANNOUNCEMENT TO TOUCHDOWN, which is the plane's run-in PLUS the fall.
--- Every block below that wants "wind the clock forward until it lands" wants
--- this rather than descentMs -- the two were the same number until the plane
--- put a release between them.
local FLIGHT = (A.planeLeadMs or 0) + A.descentMs

describe('server: the job is registered once')
do
    ok(jobs['airdrop.tick'] ~= nil, 'airdrop.tick exists')
    ok(commands['brairdrop'] ~= nil, 'and so does the dev command')
end

describe('server: scheduling')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    ok(m.airdrop ~= nil, 'a match gets airdrop state')
    eq(#m.airdrop.pending, 1, 'exactly one drop is scheduled')
    eq(#m.airdrop.live, 0, 'and nothing is in flight yet')

    local p = m.airdrop.pending[1]
    ok(p.dueAt >= gameMs + A.minDelayMs, 'due no sooner than minDelayMs')
    ok(p.dueAt <= gameMs + A.maxDelayMs, 'and no later than maxDelayMs')
end

describe('server: the probability, and the draws it must burn either way')
do
    reset()
    local realChance = A.chance

    -- chance 0.0 schedules nothing...
    A.chance = 0.0
    local a = newMatch(1)
    BR.Airdrop.begin(a)
    eq(#a.airdrop.pending, 0, 'chance 0 schedules no drop')

    -- ...and 1.0 schedules one.
    A.chance = 1.0
    local b = newMatch(1)
    BR.Airdrop.begin(b)
    eq(#b.airdrop.pending, 1, 'chance 1 schedules one')

    -- AND BOTH BURNED THE SAME NUMBER OF DRAWS. Same match id, same clock, so
    -- the same seed -- if the delay draw were skipped when the roll failed, the
    -- two streams would diverge from here and every later draw in the failing
    -- match would come from a different place in the sequence.
    eq(a.airdrop.rng:float(), b.airdrop.rng:float(),
        'a failed probability roll advances the stream exactly as a passing one does')

    A.chance = realChance
end

describe('server: perMatch')
do
    reset()
    local real = A.perMatch
    A.perMatch = 3
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    eq(#m.airdrop.pending, 3, 'perMatch is what decides how many')
    A.perMatch = 0
    local z = newMatch(2)
    BR.Airdrop.begin(z)
    ok(z.airdrop == nil, 'and zero means the subsystem does not arm at all')
    A.perMatch = real
end

describe('server: enabled')
do
    reset()
    A.enabled = false
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    ok(m.airdrop == nil, 'disabled means no state at all')
    A.enabled = true
end

describe('server: committing a drop')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()

    eq(#published, 1, 'one record goes out')
    eq(published[1].event, BR.Net.AIRDROP_SYNC, 'on the airdrop channel')
    eq(#m.airdrop.live, 1, 'and the drop is in flight')
    eq(#m.airdrop.pending, 0, 'and no longer pending')

    local rec = published[1].payload
    -- THREE TIMESTAMPS, AND THE MIDDLE ONE IS THE PLANE'S RUN-IN. Announced at
    -- tStart, released at tStart + planeLeadMs, on the ground descentMs after
    -- that. A record that collapsed the first two would be a crate appearing in
    -- the sky the instant the notification fires, with a plane already leaving.
    ok(rec.tRelease - rec.tStart == A.planeLeadMs,
        'the plane gets planeLeadMs between the announcement and the release',
        ('%s'):format(tostring(rec.tRelease - rec.tStart)))
    ok(rec.tLand - rec.tRelease == A.descentMs,
        'and the descent is descentMs long, measured from the RELEASE',
        ('%s'):format(tostring(rec.tLand - rec.tRelease)))
    ok(rec.poi ~= nil, 'the record names the POI it is landing on')

    -- THE CONTENTS DO NOT TRAVEL, the same rule a chest's contents follow: a
    -- client that knew what was inside would only run for the good ones.
    ok(rec.items == nil, 'the published record carries no contents')
    ok(#m.airdrop.live[1].items == #A.payout,
        'while the server is holding all twelve of them')

    -- The landing point obeys the rule the owner set, checked against the
    -- circle solved for the ARRIVAL time rather than for now.
    local cx, cy, r = BR.StormAt(m.storm, rec.tLand)
    ok(BR.Dist(rec.x, rec.y, cx, cy) <= r - A.insideBy,
        'the landing point is at least 250m inside the circle it will arrive in')

    -- And everyone in the match is told, in the owner's words.
    eq(#notices, 1, 'one notification')
    eq(notices[1].text,
       'An airdrop is arriving! It brings ultra-rare loot - first come, first served.',
       'with the owner\'s wording, verbatim')
    eq(#notices[1].target, 2, 'sent to the match audience, not to the server')
end

describe('server: sited against the circle it will ARRIVE in')
do
    -- THE WHOLE REASON THE SERVER CAN ANSWER THIS AT ALL is that BR.StormAt is
    -- a pure function of the record, so "will this point be inside the circle
    -- when the crate lands" is arithmetic rather than a guess. A version that
    -- asked about the circle showing NOW would pass every held-circle test and
    -- drop crates into the wall on every shrink.
    local poi = BR.Config.Map.GetPOI('lsia')

    -- Shrinking AWAY: roomy now, hopeless on arrival. Nothing may be sent.
    reset()
    local away = newMatch(1)
    away.storm = BR.BuildStormRecord(1, poi.x, poi.y, 2600.0,
        poi.x, poi.y, 100.0, gameMs, 0, FLIGHT, 1.0)
    BR.Airdrop.begin(away)
    away.airdrop.pending[1].dueAt = gameMs
    tick()
    eq(#published, 0,
        'a circle that will have collapsed by the time the crate arrives sends '
        .. 'nothing, however roomy it is right now')

    -- Sweeping IN: hopeless now, roomy on arrival. It must be sent.
    reset()
    local toward = newMatch(1)
    toward.storm = BR.BuildStormRecord(1, poi.x, poi.y, 100.0,
        poi.x, poi.y, 2600.0, gameMs, 0, FLIGHT, 1.0)
    BR.Airdrop.begin(toward)
    toward.airdrop.pending[1].dueAt = gameMs
    tick()
    eq(#published, 1,
        'and a circle that will be roomy on arrival is used even though it is '
        .. 'too small right now')
end

describe('server: the airdrop draws from its own RNG stream')
do
    -- docs/match-math.md section 1: one prime per subsystem, so the streams
    -- stay independent. Drawing an airdrop's timing or position from the loot
    -- stream would shift every downstream loot draw and change every existing
    -- layout -- silently, and only on the day the airdrop shipped.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    local mine = m.airdrop.rng:float()

    --- The value the airdrop's own stream should be at after begin's two draws.
    local function afterBegin(prime)
        local r = BR.Rng(gameMs + m.id * prime)
        r:float()
        r:int(A.minDelayMs, A.maxDelayMs)
        return r:float()
    end

    eq(mine, afterBegin(1299709), 'the airdrop folds its own prime')
    for _, p in ipairs({ 15485863, 7919, 104729 }) do
        ok(mine ~= afterBegin(p),
            ('and it is not the stream folded with %d'):format(p))
    end
end

describe('server: past storm stage 4 is a deliberate zero')
do
    reset()
    local m = newMatch(1, 2600.0, 5)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()

    eq(#published, 0, 'nothing is published past the phase cap')
    eq(#m.airdrop.pending, 0, 'and the schedule is dropped rather than retried')
    eq(#m.airdrop.live, 0, 'so this match gets no airdrop at all')

    local said = false
    for _, l in ipairs(logs) do
        if l:find('past stage', 1, true) then said = true end
    end
    ok(said, 'and the log says why, rather than the match silently getting none')
end

describe('server: no POI qualifies -- wait, never bend')
do
    reset()
    -- A circle far out to sea, so nothing on land is anywhere near it.
    local m = newMatch(1)
    m.storm = BR.BuildStormRecord(1, -6000.0, -6000.0, 400.0,
        -6000.0, -6000.0, 400.0, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()

    eq(#published, 0, 'nothing is published')
    eq(#m.airdrop.pending, 1, 'the drop stays pending and will be re-asked')
    eq(#m.airdrop.live, 0, 'and nothing is in flight')

    for _ = 1, 20 do
        gameMs = gameMs + (A.retryEveryMs or 5000)
        tick()
    end
    eq(#published, 0,
        'twenty re-asks later it has still published nothing -- the margin is '
        .. 'never relaxed and no nearest-POI fallback exists')
    eq(#m.airdrop.pending, 1, 'and it is still waiting rather than cancelled')

    -- THE NEAR MISS, WHICH IS THE ONE THAT MATTERS. A circle that CONTAINS a
    -- POI but not by 250m must still produce nothing: "inside the circle" is
    -- not the rule, "250m inside the circle" is.
    local poi = BR.Config.Map.GetPOI('lsia')
    m.storm = BR.BuildStormRecord(1, poi.x, poi.y, A.insideBy - 1.0,
        poi.x, poi.y, A.insideBy - 1.0, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0)
    gameMs = gameMs + (A.retryEveryMs or 5000)
    tick()
    eq(#published, 0,
        'a circle centred exactly on a POI still refuses it when the margin '
        .. 'does not fit')

    -- ...and the moment a circle exists that DOES hold a POI 250m inside, the
    -- same pending entry commits.
    m.storm = BR.BuildStormRecord(1, poi.x, poi.y, 2600.0,
        poi.x, poi.y, 2600.0, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0)
    gameMs = gameMs + (A.retryEveryMs or 5000)
    tick()
    eq(#published, 1, 'and it commits as soon as the circle cooperates')

    -- ONE POI, AND IT IS THAT ONE. A circle just wide enough for a single POI
    -- proves the selection is the margin rule rather than "something nearby".
    reset()
    local one = newMatch(2)
    local lsia = BR.Config.Map.GetPOI('lsia')
    one.storm = BR.BuildStormRecord(1, lsia.x, lsia.y, A.insideBy + 1.0,
        lsia.x, lsia.y, A.insideBy + 1.0, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0)
    BR.Airdrop.begin(one)
    one.airdrop.pending[1].dueAt = gameMs
    tick()
    eq(#published, 1, 'a circle with exactly one qualifying POI commits')
    eq(published[1].payload.poi, 'lsia', 'onto that POI')
end

describe('server: landing auto-opens the crate')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    local rec = published[1].payload

    eq(#spawned, 0, 'nothing is on the ground while it is still falling')

    gameMs = gameMs + FLIGHT
    tick()

    eq(#m.airdrop.live, 0, 'the drop is no longer in flight')
    eq(#spawned, #A.payout + 1, 'the husk plus every item is on the ground')

    -- The husk first, at the landing point, wearing the crate husk we already
    -- use everywhere else.
    eq(spawned[1].stack.kind, 'husk', 'the crate is left open')
    eq(spawned[1].stack.prop, BR.Config.Loot.chestOpenProp,
        'as the same husk prop the rest of the game uses')
    ok(near(spawned[1].x, rec.x, 0.001), 'at the landing point')
    ok(near(spawned[1].y, rec.y, 0.001), 'exactly')

    -- The contents in a ring around it, each carrying the origin that makes the
    -- client arc it out of the box rather than pop it into existence.
    local ringed, origined = 0, 0
    for i = 2, #spawned do
        local s = spawned[i]
        if BR.Dist(s.x, s.y, rec.x, rec.y) > 0.5 then ringed = ringed + 1 end
        if s.from and s.from.lift then origined = origined + 1 end
    end
    eq(ringed, #A.payout, 'every item lands clear of the crate')
    eq(origined, #A.payout, 'and every item bursts out of it')

    -- THE VOLTS PILE IS ONE OF THEM, and it is an ordinary registry entry --
    -- which is the whole reason it inherits the range check, the rate limit,
    -- the first-come arbitration and the not-yours-to-see refusal that
    -- docs/security.md describes. A bespoke pickup would have had to re-earn
    -- every one of those, on the highest-value entry in the match.
    local piles, explosives = 0, 0
    local exclusive = {}
    for _, w in ipairs(BR.Config.AirdropWeapons) do exclusive[w.id] = true end
    for i = 2, #spawned do
        local s = spawned[i].stack
        if s.kind == 'volts' then
            piles = piles + 1
            eq(s.count, A.voltsAmount, 'the pile is worth the configured amount')
            ok(type(s.prop) == 'string' and s.prop ~= '',
                'and carries its own prop -- no id table can resolve one for it')
        end
        if exclusive[s.item] then explosives = explosives + 1 end
    end
    eq(piles, 1, 'exactly one Volts pile lands with the drop')
    eq(explosives, 2, 'and two of the weapons found nowhere else')

    -- AND NOTHING ELSE HAPPENS. Exactly one airdrop per match, no more --
    -- including after enough time has passed for another retry to be due,
    -- which is the case a same-tick loop would not reach.
    for _ = 1, 10 do
        gameMs = gameMs + (A.retryEveryMs or 5000)
        tick()
    end
    eq(#spawned, #A.payout + 1, 'nothing lands twice')
    eq(#published, 1, 'and no second drop is announced')
    eq(#m.airdrop.pending, 0, 'the schedule is spent')
end

describe('server: the tick is inert outside PLAYING')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    m.state = BR.MatchState.ENDED
    tick()
    eq(#published, 0, 'a finished match does not commit a drop')

    m.state = BR.MatchState.PLAYING
    tick()
    eq(#published, 1, 'and a live one does')
end

describe('server: clear')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    BR.Airdrop.clear(m)
    ok(m.airdrop == nil, 'teardown is data, not cancellation')
    tick()
    eq(#published, 0, 'and a cleared match is invisible to the tick')
end

describe('server: the dev command forces a drop on a named POI')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    local poi = BR.Config.Map.GetPOI('sandy')
    ok(poi ~= nil, 'the POI the command names exists on the real map')

    commands['brairdrop'](0, { 'sandy' }, '')

    eq(#published, 1, 'a record goes out')
    ok(near(published[1].payload.x, poi.x, 0.001), 'at the POI that was named')
    ok(near(published[1].payload.y, poi.y, 0.001), 'exactly')
    eq(#m.airdrop.live, 1, 'and the drop is in flight')
    eq(#notices, 1, 'and the match is told, in the same words')

    gameMs = gameMs + FLIGHT
    tick()
    eq(#spawned, #A.payout + 1, 'and it opens on arrival like any other')

    -- A NAME THAT IS NOT A POI CHANGES NOTHING.
    reset()
    local n = newMatch(1)
    BR.Airdrop.begin(n)
    commands['brairdrop'](0, { 'not-a-poi' }, '')
    eq(#published, 0, 'an unknown POI id forces nothing')
    eq(#n.airdrop.live, 0, 'and puts nothing in flight')
end

describe('server: a match with no storm gets no drop')
do
    reset()
    local m = newMatch(1)
    m.storm = nil
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    eq(#published, 0, 'siting cannot be answered without a storm record')
    eq(#m.airdrop.pending, 0, 'and the drop is cancelled rather than retried forever')
end

-- =========================================================================
-- PART C -- the client
-- =========================================================================
--
-- br_core/client/airdrop.lua, loaded against stubbed natives. Worth the stubs
-- for one reason above all others: this file reads FOUR native BOOLs, and
-- "0 is truthy in Lua, and a native declared BOOL may answer 1 rather than
-- true" has shipped on this project four times. It is not observable in game
-- until the build that starts answering the other way.

local ents      = {}     -- [handle] = { model, x, y, z, isNetwork, dynamic }
local vehicles  = {}     -- the delivery plane
local peds      = {}     -- its pilot
local nextEnt   = 100
local blips     = {}     -- [handle] = { sprite, colour, scale, shortRange, name }
local nextBlip  = 500
local attaches  = {}
local anims     = {}
local loops     = {}
local handlers  = {}
local moves     = {}     -- every SetEntityCoords

--- What the ground probe answers, and IN WHAT SHAPE. Both halves matter: the
--- shape is the bug this project keeps shipping.
local ground = { ok = 1, z = 12.0 }
local modelLoaded = 1    -- what HasModelLoaded answers
local ptfxLoaded  = 1    -- what HasNamedPtfxAssetLoaded answers
local ptfxHandle  = 900  -- what StartParticleFxLoopedOnEntity answers next

local fxStarted, fxStopped, fxAssetUsed = {}, {}, {}

function GetHashKey(s) return s end
function IsModelValid() return 1 end
function RequestModel() end
function HasModelLoaded() return modelLoaded end
function SetModelAsNoLongerNeeded() end
function RequestAnimDict() end
function HasAnimDictLoaded() return 1 end
function PlayEntityAnim(e, anim, dict) anims[#anims + 1] = { e = e, anim = anim, dict = dict } end
function GetCurrentResourceName() return 'br_core' end

function RequestNamedPtfxAsset() end
function HasNamedPtfxAssetLoaded() return ptfxLoaded end
function UseParticleFxAsset(a) fxAssetUsed[#fxAssetUsed + 1] = a end
function StartParticleFxLoopedOnEntity(name, ent, ox, oy, oz, _, _, _, scale)
    if ptfxHandle == 0 then
        -- The failure the engine actually reports: a 0 handle, which is TRUTHY
        -- in Lua. Driven by a test below.
        fxStarted[#fxStarted + 1] = { name = name, ent = ent, handle = 0 }
        return 0
    end
    ptfxHandle = ptfxHandle + 1
    fxStarted[#fxStarted + 1] = { name = name, ent = ent, handle = ptfxHandle,
                                  ox = ox, oy = oy, oz = oz, scale = scale }
    return ptfxHandle
end
function StopParticleFxLooped(h) fxStopped[#fxStopped + 1] = h end

function CreateObjectNoOffset(model, x, y, z, isNetwork, netMission, dynamic)
    nextEnt = nextEnt + 1
    ents[nextEnt] = { model = model, x = x, y = y, z = z,
                      isNetwork = isNetwork, netMission = netMission,
                      dynamic = dynamic }
    return nextEnt
end

-- THE AIRCRAFT AND ITS CREW LIVE IN THEIR OWN TABLES, so `ents` keeps meaning
-- "the props this drop made" and every count over it stays readable. They all
-- answer DoesEntityExist, because the code under test does not care which is
-- which.
function CreateVehicle(model, x, y, z, heading, isNetwork, netMission)
    nextEnt = nextEnt + 1
    vehicles[nextEnt] = { model = model, x = x, y = y, z = z,
                          heading = heading, isNetwork = isNetwork,
                          netMission = netMission }
    return nextEnt
end
function CreatePed(_, model, x, y, z, heading, isNetwork, netMission)
    nextEnt = nextEnt + 1
    peds[nextEnt] = { model = model, x = x, y = y, z = z, heading = heading,
                      isNetwork = isNetwork, netMission = netMission }
    return nextEnt
end
function SetEntityInvincible() end
function SetBlockingOfNonTemporaryEvents() end
function SetPedIntoVehicle(ped, veh) if peds[ped] then peds[ped].inVehicle = veh end end
function SetVehicleEngineOn(v) if vehicles[v] then vehicles[v].engine = true end end
function SetEntityCoordsNoOffset(e, x, y, z)
    moves[#moves + 1] = { e = e, x = x, y = y, z = z }
    local t = ents[e] or vehicles[e] or peds[e]
    if t then t.x, t.y, t.z = x, y, z end
end
function SetEntityRotation(e, _, _, yaw)
    local t = ents[e] or vehicles[e] or peds[e]
    if t then t.heading = yaw end
end

function DoesEntityExist(e)
    return (ents[e] or vehicles[e] or peds[e]) and 1 or 0
end
function DeleteEntity(e) ents[e], vehicles[e], peds[e] = nil, nil, nil end
function SetEntityCollision() end
function FreezeEntityPosition() end
function SetEntityHeading() end
function SetEntityCoords(e, x, y, z)
    moves[#moves + 1] = { e = e, x = x, y = y, z = z }
    if ents[e] then ents[e].x, ents[e].y, ents[e].z = x, y, z end
end
function AttachEntityToEntity(child, parent, _, ox, oy, oz)
    attaches[#attaches + 1] = { child = child, parent = parent,
                                ox = ox, oy = oy, oz = oz }
end
function GetGroundZFor_3dCoord() return ground.ok, ground.z end

function AddBlipForCoord(x, y, z)
    nextBlip = nextBlip + 1
    blips[nextBlip] = { x = x, y = y, z = z }
    return nextBlip
end
function DoesBlipExist(b) return blips[b] and 1 or 0 end
function RemoveBlip(b) blips[b] = nil end
function SetBlipSprite(b, s) if blips[b] then blips[b].sprite = s end end
function SetBlipColour(b, c) if blips[b] then blips[b].colour = c end end
function SetBlipScale(b, s) if blips[b] then blips[b].scale = s end end
function SetBlipAsShortRange(b, v) if blips[b] then blips[b].shortRange = v end end

Citizen = {
    -- Synchronous, so the model-load thread finishes inside the call that
    -- started it. Nothing here is testing concurrency.
    CreateThread = function(fn) fn() end,
    Wait = function() end,
}

function RegisterNetEvent() end
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = fn
end
local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

BR.Loop = {
    FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
    register = function(_, name, fn) loops[name] = fn end,
}
BR.State  = { me = { state = BR.PlayerState.ALIVE } }
BR.Native = {
    blipName = function(b, n) if blips[b] then blips[b].name = n end end,
}

loadAll({ 'br_core/client/airdrop.lua' })

local render = loops['airdrop.render']

local function clientReset()
    fire('onResourceStop', 'br_core')
    ents, blips, attaches, anims, moves = {}, {}, {}, {}, {}
    vehicles, peds = {}, {}
    fxStarted, fxStopped, fxAssetUsed = {}, {}, {}
    ground.ok, ground.z = 1, 12.0
    modelLoaded, ptfxLoaded = 1, 1
    ptfxHandle = 900
    BR.State.me.state = BR.PlayerState.ALIVE
    gameMs = gameMs + 1000000
end

--- Every entity currently alive, by model name.
local function entsOfModel(model)
    local out = {}
    for h, e in pairs(ents) do
        if e.model == model then out[#out + 1] = h end
    end
    table.sort(out)
    return out
end

--- The delivery plane, and the pilot who keeps its propellers turning.
local function onePlane()
    for _, v in pairs(vehicles) do return v end
    return nil
end

local function onePed()
    for _, p in pairs(peds) do return p end
    return nil
end

--- How many entities exist at all.
local function entCount()
    local n = 0
    for _ in pairs(ents) do n = n + 1 end
    return n
end

--- Announce a drop to the client, starting now.
local function announce(alt, span)
    local rec = BR.BuildAirdropRecord(1,
        { id = 'lsia', x = 100.0, y = 200.0, z = 30.0 },
        alt or 260.0, gameMs, gameMs + (span or A.descentMs), 90.0)
    fire(BR.Net.AIRDROP_SYNC, rec)
    return rec
end

local function oneBlip()
    for _, b in pairs(blips) do return b end
    return nil
end

local function oneEnt()
    local first = nil
    for h in pairs(ents) do
        if not first or h < first then first = h end
    end
    return first and ents[first] or nil, first
end

--- The last SetEntityCoords written for the crate specifically.
---
--- NOT `moves[#moves]`, WHICH IS NOW A FLARE. A drop writes four positions a
--- frame, in a fixed order, and a test that reads the last one is measuring the
--- second flare's offset position rather than the crate's descent -- which would
--- pass while the crate fell to the wrong height by half a metre.
local function crateMove()
    local _, crate = oneEnt()
    if not crate then return nil end
    for i = #moves, 1, -1 do
        if moves[i].e == crate then return moves[i] end
    end
    return nil
end

describe('client: the blip')
do
    clientReset()
    announce()

    local b = oneBlip()
    ok(b ~= nil, 'a blip goes up the moment the drop is announced')
    eq(b.sprite, A.blipSprite, 'with the sprite the owner asked for')
    eq(b.colour, A.blipColour, 'and the configured colour')
    ok(b.shortRange == false,
        'and it is NOT short range -- everyone in the match must see it')
    eq(b.name, A.blipName, 'and it is named, so the legend is not a heist')

    -- A re-send replaces rather than stacking a second blip on the same drop.
    announce()
    local n = 0
    for _ in pairs(blips) do n = n + 1 end
    eq(n, 1, 'a re-sent record replaces rather than duplicating')
end

describe('client: the plane flies, then leaves')
do
    -- Announced now, released planeLeadMs later, on the ground descentMs after
    -- that -- the real shape, which every other client block flattens by
    -- letting tRelease default to tStart.
    clientReset()
    local t0  = gameMs
    local rel = t0 + A.planeLeadMs
    local rec = BR.BuildAirdropRecord(1,
        { id = 'lsia', x = 100.0, y = 200.0, z = 30.0 },
        260.0, t0, rel + A.descentMs, 0.0, rel)
    fire(BR.Net.AIRDROP_SYNC, rec)
    render()

    local plane = onePlane()
    ok(plane ~= nil, 'a plane is in the air from the announcement')
    ok(plane and plane.model == A.planeModel, 'and it is the configured model')
    ok(plane and plane.isNetwork == false,
        'local and non-networked, like everything else this file makes')
    ok(onePed() ~= nil,
        'with a pilot aboard -- a prop aircraft shuts its engine off empty')
    ok(plane and plane.engine == true, 'and its engine running')

    -- THE CRATE IS STILL INSIDE IT. Building one now would put a box in the sky
    -- under an aircraft that has not reached it, which is the picture the
    -- run-in exists to replace.
    eq(oneEnt(), nil, 'and no crate, because it has not been released yet')

    -- INBOUND. Heading 0 is north, so it comes up from the south and the
    -- distance closes as the release approaches.
    local far = BR.Dist(plane.x, plane.y, rec.x, rec.y)
    ok(far > 100.0, 'it starts a long way out', ('%.0fm'):format(far))
    ok(plane.y < rec.y, 'south of the drop point, inbound')

    gameMs = gameMs + A.planeLeadMs
    render()
    plane = onePlane()
    ok(plane and BR.Dist(plane.x, plane.y, rec.x, rec.y) < 1.0,
        'and is directly over the drop point at the release',
        plane and ('%.1fm'):format(BR.Dist(plane.x, plane.y, rec.x, rec.y)))
    ok(oneEnt() ~= nil, 'which is when the crate appears')

    -- OUTBOUND, and gone when its trail window closes -- long before the crate
    -- lands. A Titan orbiting the drop for another half-minute is scenery
    -- arguing with the fight underneath it.
    gameMs = gameMs + A.planeTrailMs
    render()
    ok(onePlane() ~= nil, 'still there at the end of the trail window')
    ok(onePlane().y > rec.y, 'north of the drop point now, outbound')

    gameMs = gameMs + 1
    render()
    eq(onePlane(), nil, 'and gone a millisecond later')
    eq(onePed(), nil, 'pilot and all')
    ok(oneEnt() ~= nil, 'while the crate is still falling')

    -- Teardown takes the aircraft too, whenever it happens. A fresh record,
    -- because the clock has been wound past the one above's trail window.
    clientReset()
    local t1  = gameMs
    local rel1 = t1 + A.planeLeadMs
    fire(BR.Net.AIRDROP_SYNC, BR.BuildAirdropRecord(1,
        { id = 'lsia', x = 100.0, y = 200.0, z = 30.0 },
        260.0, t1, rel1 + A.descentMs, 0.0, rel1))
    render()
    ok(onePlane() ~= nil, 'a plane is up')
    fire(BR.Net.STATE, { state = BR.MatchState.ENDED })
    eq(onePlane(), nil, 'and the match ending removes it')
    eq(onePed(), nil, 'with its pilot')
end

describe('client: a clock running behind does not lose the drop')
do
    -- THE 2026-08-22 PLAYTEST BUG, END TO END. `tStart` is the SERVER's timer;
    -- the client compares it against BR.Clock.now(), which is a median-of-eight
    -- ESTIMATE of that timer. A client whose estimate is 200ms behind used to
    -- destroy the drop -- blip, crate, record -- on the first frame after being
    -- told an airdrop was coming, and nothing anywhere said so.
    clientReset()
    BR.Clock.offset = -200.0
    announce(260.0, 30000)

    ok(oneBlip() ~= nil, 'the blip goes up when the record arrives')
    render()
    ok(oneBlip() ~= nil, 'and is still there after a frame the clock calls early')

    -- ...and the moment the estimate catches up, everything proceeds normally.
    BR.Clock.offset = 0.0
    render()
    ok(oneBlip() ~= nil, 'the blip survived')
    ok(oneEnt() ~= nil, 'and the crate is built rather than never existing')

    BR.Clock.offset = 0.0
end

describe('client: the blip is re-asserted, not assumed')
do
    -- The marker is the only thing telling the match where to run. If anything
    -- at all removes it while the drop is live -- another resource sweeping
    -- blips, a handle gone bad -- it comes back on the next frame rather than
    -- leaving the match's one airdrop unfindable.
    clientReset()
    announce(260.0, 30000)
    render()

    local before = oneBlip()
    ok(before ~= nil, 'there is a blip')
    for h in pairs(blips) do RemoveBlip(h) end
    eq(oneBlip(), nil, 'something took it away')

    render()
    ok(oneBlip() ~= nil, 'and the next frame puts it back')

    -- ONCE, THOUGH. Re-asserting has to be idempotent or a frame loop makes a
    -- blip per frame and the pause map fills with sixty copies a second.
    render(); render(); render()
    local n = 0
    for _ in pairs(blips) do n = n + 1 end
    eq(n, 1, 'and exactly one, however many frames pass')

    -- BUT NOT AFTER THE WINDOW CLOSES. A blip that reappeared forever would be
    -- worse than one that vanished early.
    gameMs = gameMs + 30000 + A.blipLingerMs + 1
    render()
    eq(oneBlip(), nil, 'once the drop expires it stays gone')
end

describe('client: the diagnosis command')
do
    -- WORTH A TEST BECAUSE IT IS WHAT GETS RUN WHEN THIS BREAKS AGAIN. An
    -- airdrop happens once a match and its blip lives about ninety seconds, so a
    -- command that errors is a whole round spent learning nothing.
    clientReset()
    local diag = commands['brairdrop']
    ok(diag ~= nil, 'the client registers one')

    local said = {}
    local realPrintFn = print
    print = function(s) said[#said + 1] = tostring(s) end

    diag(0, {}, '')
    local emptyLines = #said

    announce(260.0, 30000)
    render()
    diag(0, {}, '')

    print = realPrintFn

    ok(emptyLines > 0, 'it says something with no drop in flight')
    local joined = table.concat(said, '\n')
    ok(joined:find('clock', 1, true) ~= nil,
        'it reports the clock, which is the number that broke this')
    ok(joined:find('blip handle', 1, true) ~= nil,
        'and whether a blip actually exists')
    ok(joined:find('flares', 1, true) ~= nil, 'and what was built')
end

describe('client: a malformed record is ignored')
do
    clientReset()
    fire(BR.Net.AIRDROP_SYNC, nil)
    fire(BR.Net.AIRDROP_SYNC, 'nope')
    fire(BR.Net.AIRDROP_SYNC, {})
    fire(BR.Net.AIRDROP_SYNC, { x = 1.0, y = 2.0 })              -- no times
    fire(BR.Net.AIRDROP_SYNC, { tStart = 0, tLand = 1 })         -- no position
    eq(oneBlip(), nil, 'nothing is drawn for a record that is not one')
end

describe('client: every part is local and non-networked')
do
    clientReset()
    announce()
    render()

    local e = oneEnt()
    ok(e ~= nil, 'the crate is built')
    eq(e.model, A.crateProp, 'and it is the crate prop we already use')

    -- FOUR OBJECTS, AND EVERY ONE OF THEM NON-NETWORKED. This is not a style
    -- check: `sv_entityLockdown relaxed` refuses a client-created NETWORKED
    -- entity outright, so a single `true` here is an object that silently never
    -- appears for anyone.
    eq(entCount(), 4, 'a crate, a canopy and two flares')
    local networked = 0
    for _, x in pairs(ents) do
        if x.isNetwork ~= false then networked = networked + 1 end
    end
    eq(networked, 0, 'and none of them is networked')

    eq(#entsOfModel(A.chuteModel), 1, 'the canopy exists')
    eq(#entsOfModel(A.flareProp), 2, 'and a flare on each side')
    ok(#anims >= 1, 'and the canopy deploy anim is played')

    -- NOTHING IS ATTACHED TO ANYTHING. The canopy and the flares are positioned
    -- from the same solver as the crate; an ATTACH_ENTITY_TO_ENTITY would be a
    -- second mechanism deciding where a part of the drop is, and this suite
    -- could not see it at all.
    eq(#attaches, 0, 'and nothing is attached to anything')
end

describe('client: the flares trail smoke')
do
    clientReset()
    announce()
    render()

    eq(#fxStarted, 2, 'one looped effect, on each flare')
    local flares = entsOfModel(A.flareProp)
    local onFlare = 0
    for _, f in ipairs(fxStarted) do
        eq(f.name, A.flarePtfxName, 'the configured effect')
        for _, h in ipairs(flares) do
            if f.ent == h then onFlare = onFlare + 1 end
        end
    end
    eq(onFlare, 2,
        'anchored to the FLARES rather than started at a coordinate -- an '
        .. 'emitter that does not ride the fall leaves no trail')

    -- USE_PARTICLE_FX_ASSET IS PER CALL. Asserted because the symptom of
    -- missing it is not an error: the effect resolves against whatever asset
    -- was named last, which on a quiet frame is nothing at all.
    eq(#fxAssetUsed, 2, 'the asset is re-asserted before every start')

    -- ...and both are stopped, before the entities they are anchored to are
    -- deleted. A looped effect outlives its entity -- that is what looped means
    -- -- so the other order leaves an emitter running in mid-air forever.
    local n = #fxStopped
    gameMs = gameMs + A.descentMs
    render()
    eq(#fxStopped - n, 2, 'and both are stopped on touchdown')
    eq(#entsOfModel(A.flareProp), 0, 'with the flares deleted')
end

describe('client: a particle asset that will not stream costs nothing')
do
    -- Best-effort, exactly as the canopy's deploy anim is. A flare with no
    -- smoke still reads as a flare; a drop that failed to arrive because a
    -- particle asset was missing is a match without its airdrop.
    clientReset()
    ptfxLoaded = 0
    announce()
    render()
    eq(#fxStarted, 0, 'no effect is started')
    eq(#entsOfModel(A.flareProp), 2, 'but the flares are still there')
    eq(entCount(), 4, 'and so is everything else')

    -- AND A START THAT ANSWERS 0 IS A FAILURE, not a handle. 0 is TRUTHY in
    -- Lua, so a stored zero would be handed to StopParticleFxLooped at teardown.
    clientReset()
    ptfxHandle = 0
    announce()
    render()
    eq(#fxStarted, 2, 'the start was attempted')
    local before = #fxStopped
    gameMs = gameMs + A.descentMs
    render()
    eq(#fxStopped - before, 0, 'and a 0 handle is never stopped')
end

describe('client: the descent')
do
    clientReset()
    local rec = announce(260.0, 30000)
    render()
    local last = crateMove()
    ok(last ~= nil, 'the crate is positioned')
    ok(near(last.z, ground.z + 260.0, 0.001), 'starting 260m above the ground')
    ok(near(last.x, rec.x, 0.001), 'over the POI')

    gameMs = gameMs + 15000
    render()
    last = crateMove()
    ok(near(last.z, ground.z + 130.0, 0.001), 'halfway down halfway through')

    -- EVERY PART FALLS WITH IT. The canopy and the flares are separate objects,
    -- so "the crate is at the right height" says nothing about them -- and a
    -- canopy left at 260m while the crate falls out from under it is exactly
    -- what an attachment would have hidden.
    local crateZ = last.z
    local chute = entsOfModel(A.chuteModel)[1]
    ok(chute ~= nil and near(ents[chute].z,
        crateZ + (A.chuteOffset.z or 0.1), 0.001),
        'the canopy is directly over it, at its own offset')
    local flares = entsOfModel(A.flareProp)
    for _, h in ipairs(flares) do
        ok(near(ents[h].z, crateZ + (A.flareOffset.z or 0.0), 0.001),
            'and each flare is at the crate\'s height')
        ok(near(BR.Dist(ents[h].x, ents[h].y, rec.x, rec.y),
                A.flareOffset.x, 0.001),
            'and out to the side by exactly the configured offset')
    end

    -- ON OPPOSITE SIDES, which "each one is 0.55m from the crate" does not say
    -- -- both flares stacked on the same side satisfy every check above, and a
    -- mutation pass proved it by flipping the sign and surviving. Left and right
    -- is the owner's whole instruction.
    eq(#flares, 2, 'there are two of them')
    ok(near(BR.Dist(ents[flares[1]].x, ents[flares[1]].y,
                    ents[flares[2]].x, ents[flares[2]].y),
            A.flareOffset.x * 2.0, 0.001),
        'and they are a full diameter apart -- one offset, two signs',
        ('%.3f apart'):format(BR.Dist(ents[flares[1]].x, ents[flares[1]].y,
                                      ents[flares[2]].x, ents[flares[2]].y)))

    -- Touchdown: the props go, the blip stays.
    gameMs = gameMs + 15000
    render()
    eq(oneEnt(), nil, 'the falling crate is deleted on touchdown')
    eq(entCount(), 0, 'and so is every part of it')
    ok(oneBlip() ~= nil, 'but the blip is still up')

    -- ...for exactly one more minute.
    gameMs = gameMs + A.blipLingerMs
    render()
    ok(oneBlip() ~= nil, 'still up one minute after landing')
    gameMs = gameMs + 1
    render()
    eq(oneBlip(), nil, 'and gone a millisecond later')
end

describe('client: BOOL natives, both wrong shapes')
do
    -- THE FOUR-TIMES BUG, in both directions at once.
    --
    -- A native declared BOOL may answer 1 rather than true, so `v == true` is
    -- false for a yes. And IN LUA 0 IS TRUTHY, so `if v then` is true for a no.
    -- A fix has to survive both rows or it has only moved the fault.

    -- The probe says NO, with a zero. A guard written `if ok then` would take
    -- the zero as a yes and fall to the probe's garbage z instead of the POI's
    -- authored height.
    clientReset()
    ground.ok, ground.z = 0, -9999.0
    local rec = announce(260.0, 30000)
    render()
    local last = crateMove()
    ok(near(last.z, rec.gz + 260.0, 0.001),
        'a probe answering 0 is a refusal, so the POI height stands in',
        last and last.z)

    -- The probe says YES, with a one. A guard written `ok == true` would
    -- discard a perfectly good answer.
    clientReset()
    ground.ok, ground.z = 1, 44.0
    announce(260.0, 30000)
    render()
    last = crateMove()
    ok(near(last.z, 44.0 + 260.0, 0.001),
        'a probe answering 1 is an answer, and it is used', last and last.z)

    -- HasNamedPtfxAssetLoaded is the fifth BOOL native in this file and the
    -- newest, so it gets the same pair. A 0 must be a refusal...
    clientReset()
    ptfxLoaded = 0
    announce()
    render()
    eq(#fxStarted, 0, 'a ptfx asset answering 0 starts nothing')

    -- ...and a 1 must be an answer.
    clientReset()
    ptfxLoaded = 1
    announce()
    render()
    eq(#fxStarted, 2, 'and one answering 1 starts both trails')

    -- HasModelLoaded answering 1 must build the crate...
    clientReset()
    modelLoaded = 1
    announce()
    render()
    ok(oneEnt() ~= nil, 'a model that loaded with a 1 builds the prop')

    -- ...and answering 0 must not, rather than building from an unloaded model.
    clientReset()
    modelLoaded = 0
    announce()
    render()
    eq(oneEnt(), nil, 'a model that answered 0 builds nothing')
    modelLoaded = 1
end

describe('client: teardown')
do
    -- Back at the lobby vista: this match's crate is not this player's problem,
    -- the same rule client/storm.lua applies to the wall.
    clientReset()
    announce()
    render()
    ok(oneEnt() ~= nil, 'a crate is in the air')
    BR.State.me.state = BR.PlayerState.LOBBY
    render()
    eq(oneEnt(), nil, 'and it is gone once the player is back in the lobby')
    eq(oneBlip(), nil, 'blip and all')

    -- The match ending takes it too, so nothing falls through the verdict slam.
    for _, st in ipairs({ BR.MatchState.WAITING, BR.MatchState.ENDED,
                          BR.MatchState.CLEANUP }) do
        clientReset()
        announce()
        render()
        fire(BR.Net.STATE, { state = st })
        eq(oneEnt(), nil, ('%s clears the crate'):format(st))
        eq(oneBlip(), nil, ('%s clears the blip'):format(st))
    end

    -- A TEARDOWN MID-STREAM BUILDS NOTHING. The model load takes frames and a
    -- match can end inside them; the spawn thread re-checks the record, and a
    -- torn-down drop no longer has one.
    clientReset()
    local deferred = nil
    local realCreate = Citizen.CreateThread
    Citizen.CreateThread = function(fn) deferred = fn end
    announce()
    render()                         -- queues the spawn; the thread does not run
    ok(deferred ~= nil, 'the spawn is queued')
    eq(oneEnt(), nil, 'and nothing exists while the model is still streaming')

    fire(BR.Net.STATE, { state = BR.MatchState.CLEANUP })   -- the match ends
    Citizen.CreateThread = realCreate
    deferred()                       -- ...and only now does the model arrive
    eq(oneEnt(), nil,
        'a stream that finishes after teardown builds nothing, rather than '
        .. 'leaving a crate in the sky with nothing left that knows it exists')

    -- And a resource restart, or the props outlive everything that knows about
    -- them.
    clientReset()
    announce()
    render()
    fire('onResourceStop', 'br_other')
    ok(oneEnt() ~= nil, 'another resource stopping is not our business')
    fire('onResourceStop', 'br_core')
    eq(oneEnt(), nil, 'ours is')
    eq(oneBlip(), nil, 'and it takes the blip with it')
end

-- ----------------------------------------------------------------- result ---

print = realPrint

io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
