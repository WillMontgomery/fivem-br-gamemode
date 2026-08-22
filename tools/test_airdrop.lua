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
end

describe('config: exclusive loot is exclusive')
do
    ok(#BR.Config.AirdropItems > 0, 'there is at least one airdrop-only item')

    for _, c in ipairs(BR.Config.AirdropItems) do
        ok(BR.Config.ConsumableById[c.id] == c,
            ('%s resolves by id, so the inventory and the labels can see it')
                :format(c.id))

        -- Listed, so /brgrant and /brpropscale enumerate it...
        local listed = false
        for _, x in ipairs(BR.Config.Consumables) do
            if x.id == c.id then listed = true end
        end
        ok(listed, ('%s is in BR.Config.Consumables'):format(c.id))

        -- ...and in NO bucket, because a bucket is the only thing
        -- BR.RollLootStack ever rolls against. This is the whole of "found
        -- nowhere else".
        local bucketed = false
        for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
            for _, x in ipairs(BR.Config.ConsumablesByRarity[r] or {}) do
                if x.id == c.id then bucketed = true end
            end
            for _, x in ipairs(BR.Config.ConsumablesByRarityFloor[r] or {}) do
                if x.id == c.id then bucketed = true end
            end
        end
        ok(not bucketed,
            ('%s is in no rarity bucket, so no world roll can produce it')
                :format(c.id))
    end
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

    -- THE #191 SEAM. `cprkit` is named in the pool and does not exist yet, so
    -- it is dropped at resolution. The day it is registered this test changes
    -- and nothing else does.
    local hasCpr = false
    for _, t in ipairs(A.resolvedPools.exclusive) do
        if t.item == 'cprkit' then hasCpr = true end
    end
    if BR.Config.ConsumableById.cprkit then
        ok(hasCpr, 'cprkit exists, so it is in the exclusive pool')
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

describe('config: the world layout is untouched')
do
    -- THE PROPERTY THAT CANNOT BE SEEN IN GAME. Appending to
    -- BR.Config.Consumables after loot.lua has bucketed it is correct and
    -- subtle, and the failure mode -- a Heavy Shield in an ordinary crate -- is
    -- one crate in hundreds. So generate a whole match's layout and look.
    local exclusive = {}
    for _, c in ipairs(BR.Config.AirdropItems) do exclusive[c.id] = true end

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
    for _, c in ipairs(BR.Config.AirdropItems) do excl[c.id] = true end

    local hits = 0
    for seed = 1, 20 do
        for _, s in ipairs(BR.AirdropPayout(BR.Rng(seed), A)) do
            if excl[s.item] then hits = hits + 1 end
        end
    end
    ok(hits >= 20,
        'every drop carries at least one item that is found nowhere else', hits)
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
    ok(rec.tLand - rec.tStart == A.descentMs, 'the descent is descentMs long')
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
        poi.x, poi.y, 100.0, gameMs, 0, A.descentMs, 1.0)
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
        poi.x, poi.y, 2600.0, gameMs, 0, A.descentMs, 1.0)
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

    gameMs = gameMs + A.descentMs
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

    gameMs = gameMs + A.descentMs
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

function GetHashKey(s) return s end
function IsModelValid() return 1 end
function RequestModel() end
function HasModelLoaded() return modelLoaded end
function SetModelAsNoLongerNeeded() end
function RequestAnimDict() end
function HasAnimDictLoaded() return 1 end
function PlayEntityAnim(e, anim, dict) anims[#anims + 1] = { e = e, anim = anim, dict = dict } end
function GetCurrentResourceName() return 'br_core' end

function CreateObjectNoOffset(model, x, y, z, isNetwork, netMission, dynamic)
    nextEnt = nextEnt + 1
    ents[nextEnt] = { model = model, x = x, y = y, z = z,
                      isNetwork = isNetwork, netMission = netMission,
                      dynamic = dynamic }
    return nextEnt
end
function DoesEntityExist(e) return ents[e] and 1 or 0 end
function DeleteEntity(e) ents[e] = nil end
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
    ground.ok, ground.z = 1, 12.0
    modelLoaded = 1
    BR.State.me.state = BR.PlayerState.ALIVE
    gameMs = gameMs + 1000000
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

describe('client: the crate is local and non-networked')
do
    clientReset()
    announce()
    render()

    local e = oneEnt()
    ok(e ~= nil, 'the crate is built')
    ok(e.isNetwork == false,
        'with isNetwork = false -- sv_entityLockdown refuses anything else')
    eq(e.model, A.crateProp, 'and it is the crate prop we already use')

    eq(#attaches, 1, 'the canopy is attached to it')
    local off = A.chuteOffset
    ok(near(attaches[1].oz, off.z, 1e-9), 'at Rockstar\'s own offset')
    ok(#anims >= 1, 'and the deploy anim is played')

    local chute = ents[attaches[1].child]
    ok(chute ~= nil and chute.isNetwork == false,
        'the canopy is non-networked too')
end

describe('client: the descent')
do
    clientReset()
    local rec = announce(260.0, 30000)
    render()
    local last = moves[#moves]
    ok(last ~= nil, 'the crate is positioned')
    ok(near(last.z, ground.z + 260.0, 0.001), 'starting 260m above the ground')
    ok(near(last.x, rec.x, 0.001), 'over the POI')

    gameMs = gameMs + 15000
    render()
    last = moves[#moves]
    ok(near(last.z, ground.z + 130.0, 0.001), 'halfway down halfway through')

    -- Touchdown: the props go, the blip stays.
    gameMs = gameMs + 15000
    render()
    eq(oneEnt(), nil, 'the falling crate is deleted on touchdown')
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
    local last = moves[#moves]
    ok(near(last.z, rec.gz + 260.0, 0.001),
        'a probe answering 0 is a refusal, so the POI height stands in',
        last and last.z)

    -- The probe says YES, with a one. A guard written `ok == true` would
    -- discard a perfectly good answer.
    clientReset()
    ground.ok, ground.z = 1, 44.0
    announce(260.0, 30000)
    render()
    last = moves[#moves]
    ok(near(last.z, 44.0 + 260.0, 0.001),
        'a probe answering 1 is an answer, and it is used', last and last.z)

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
