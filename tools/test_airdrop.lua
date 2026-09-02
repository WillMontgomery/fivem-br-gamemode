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
    -- TWICE THE SIZE (owner, 2026-08-22: "The blip needs to be 2x larger
    -- please."). 1.2 is what they saw and asked to double.
    eq(A.blipScale, 2.4, 'drawn at twice the size the playtest saw')
    -- THE BLIP'S TWO NUMBERS (owner, 2026-08-22: "we keep the blip on until 1
    -- minute after the crate is opened, or no longer than 4 minutes if
    -- unopened"). Pinned as literals because they are the owner's, and because
    -- the second one is the ONLY thing that bounds a drop nobody ever opens --
    -- the same playtest deleted the auto-open, so "never opened" is reachable.
    eq(A.blipAfterOpenMs, 60000, 'the blip lives a minute past the open')
    eq(A.blipMaxMs, 240000, 'and four minutes past the announcement regardless')
    ok(A.blipLingerMs == nil,
        'and the old land-relative linger is GONE rather than left to rot')

    -- 10 TO 14 (owner, 2026-08-22: "let's make it 10-14 items in these
    -- airdrops"). The array is longer than the maximum would need only if
    -- somebody added a slot without moving maxItems, which is why both are
    -- checked against it.
    eq(A.minItems, 10, 'at least ten items')
    eq(A.maxItems, 14, 'and at most fourteen')
    eq(#A.payout, 14, 'and the array is long enough to deal the maximum')
    ok(A.maxItems <= #A.payout,
        'maxItems can never ask for a slot that does not exist')
    ok(A.minItems <= A.maxItems, 'and the range is the right way round')

    -- THE ORDER IS LOAD-BEARING AND THIS IS THE ASSERTION THAT SAYS SO. A
    -- minimum roll deals the FIRST minItems slots, so a drop that pays an RPG
    -- and no heavy ammo is one careless reorder away. Ammo is inside the
    -- guaranteed ten on purpose.
    local guaranteed = {}
    for i = 1, A.minItems do guaranteed[A.payout[i]] = (guaranteed[A.payout[i]] or 0) + 1 end
    eq(guaranteed.exclusive, 2, 'the smallest drop still holds both exclusives')
    eq(guaranteed.volts, 1, 'and the Volts')
    eq(guaranteed.ammo, 2, 'and both ammo slots -- never an RPG with no rounds')
    ok((guaranteed.legendary or 0) >= 2, 'and at least two legendaries')
    ok((guaranteed.healing or 0) >= 1, 'and something to heal with')
    ok((guaranteed.throwable or 0) >= 1, 'and something to throw')

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

    -- ═══ THE FLARES ARE A PROJECTILE NOW, AND NO MODEL WAS EVER GOING TO
    --     WORK ═══
    --
    -- The 2026-08-21 flares shipped `prop_flare_01a`, which is not a model at
    -- all. The 2026-08-22 flares shipped a candidate list, loaded one of three
    -- real models, and the owner still saw nothing -- because every visual a
    -- flare has lives in AMMO_FLARE's CAmmoThrownInfo and is applied by the
    -- PROJECTILE controller. `w_am_flare` is only the drawable it wears.
    --
    -- No test outside a running client can prove any of that renders. What it
    -- CAN pin is the shape of the decision: that the default route is the
    -- projectile one, that the numbers the projectile route depends on are
    -- inside the bounds that make them work, and that the fake model name never
    -- comes back.
    eq(A.flareRoute, 'projectile',
        'the default route is a real fired flare, not a prop')
    ok(type(A.flareWeapon) == 'string' and A.flareWeapon ~= '',
        'and it names a weapon to fire')

    -- NON-ZERO, AND IT IS LOAD-BEARING IN BOTH DIRECTIONS. Big enough and the
    -- flare travels, which is the ballistic objection this route had to answer;
    -- ZERO and the reference resource's own comment says it "remains static and
    -- won't remove itself later" -- so the engine's expiry, which is the only
    -- reason we may create something we hold no handle to, depends on this.
    ok((A.flareEpsilon or 0.0) > 0.0,
        'the shot has a non-zero separation, or the flare never expires')
    ok((A.flareEpsilon or 1.0) < 0.01,
        'and a tiny one, or the flare flies off instead of standing still')

    -- ═══ ONE CADENCE, AND IT ONLY APPLIES WHILE SOMETHING IS FALLING ═══
    --
    -- The descent has to light more than one, or a "trail" is one flare hanging
    -- at the release altitude while the crate falls away from it.
    ok((A.flareFallRefireMs or 0) > 0
       and (A.flareFallRefireMs or 0) * 2 <= (A.descentMs or 0),
        'the descent cadence fires at least twice on the way down, which is '
        .. 'what makes a trail rather than a dot')

    -- ═══ AND THE LANDED KNOBS ARE GONE, WHICH IS THE ASSERTION ═══
    --
    -- Owner, 2026-08-23: "Seems the husk keeps getting more and more flares
    -- indefinitely though... If we drop the husk flares and keep the
    -- free-falling ones I'd be happy with that."
    --
    -- A LANDED BOX DOES NOT MOVE, so the cadence that paints a column behind a
    -- falling crate just stacks pairs on a stationary one until the match ends.
    -- These two keys are what drove that pass; asserting they are ABSENT is what
    -- stops somebody restoring the config half of the feature and wondering why
    -- nothing reads it. The behavioural half is pinned in 'client: a landed box
    -- never gets flares' below.
    eq(A.flareOnLanded, nil,
        'flareOnLanded is gone -- the owner watched the husk collect flares '
        .. 'forever and asked for that half back out')
    eq(A.flareRefireMs, nil,
        'and the landed cadence with it, because nothing re-lights a box that '
        .. 'has stopped moving')

    -- The object route is the fallback and its numbers still have to be sane,
    -- because it is one console command away and it is what gets reached for
    -- when the projectile route shows nothing.
    ok(type(A.flareModel) == 'string' and A.flareModel ~= '',
        'the fallback route names exactly one model rather than a chain')
    local sawFake = (A.flareModel == 'prop_flare_01a')
    for _, n in ipairs(A.flareAlternatives or {}) do
        ok(type(n) == 'string' and n ~= '', 'every named alternative is a name')
        if n == 'prop_flare_01a' then sawFake = true end
    end
    ok(not sawFake,
        'and prop_flare_01a -- which is not a model, and is the whole of the '
        .. 'first invisible-flare bug -- is named nowhere')
    ok(type(A.flarePtfxAsset) == 'string' and A.flarePtfxAsset ~= '',
        'the fallback has a particle asset to stream')
    ok(type(A.flarePtfxName) == 'string' and A.flarePtfxName ~= '',
        'and an effect inside it')
    ok((A.flarePtfxScale or 0.0) > 0.0,
        'and a scale above zero -- a zero-scale effect renders nothing and '
        .. 'reports a perfectly healthy handle')
    ok((A.flareScale or 0.0) > 1.0,
        'and the prop is scaled up, because a foot-long flare 170m away is a '
        .. 'pixel')

    ok(A.flareOffset and (A.flareOffset.x or 0.0) > 0.0,
        'and an offset with a positive x -- the sign is what makes it two sides')
    -- The crate is drawn at 2x now, so an offset that used to clear it may not.
    ok((A.flareOffset.x or 0.0) >= (A.crateScale or 1.0) * 0.5,
        'and the offset clears a crate drawn at crateScale rather than sitting '
        .. 'inside it')
end

describe('config: the Cargobob came down, and what that traded')
do
    -- Owner, 2026-08-22: "The cargobob seemed to be too high off the ground
    -- when it came in. I could barely hear it."
    --
    -- ═══ 2026-08-23: 250m UP AND TWICE AS FAST DOWN ═══
    --
    -- Owner: "fly the cargobob 250m above that... Also please make the loot drop
    -- 2x the speed."
    --
    -- THE THREE NUMBERS HAVE TO ADD UP AND THIS IS WHERE THAT IS ENFORCED.
    -- config/airdrop.lua writes `altitude` as a literal rather than computing it
    -- -- a config file that does arithmetic is one you cannot read the value of
    -- -- so the invariant lives here instead. The crate is released from
    -- `altitude` and the aircraft holds `planeHeight`; if those stop differing
    -- by exactly `planeAltAbove` the box no longer leaves the Cargobob, it
    -- appears somewhere near it.
    eq(A.planeHeight, 250.0, 'the Cargobob flies 250m over the drop point')
    eq(A.planeAltAbove, 25.0, 'with the crate 25m beneath it')
    eq(A.altitude, 225.0, 'so the crate is released from 225m')
    ok(near(A.altitude + A.planeAltAbove, A.planeHeight),
        'and those three add up, which is what makes the release exact')
    -- HALVED, AS ASKED. `descentMs` is what "2x the speed" means when the height
    -- is a separate instruction -- and since 2026-08-28 it is the CRUISE-RATE
    -- reference rather than the length of the fall: the crate holds
    -- `altitude / descentMs` for nearly all of the descent and then flares.
    eq(A.descentMs, 15000, 'and the fall takes half the thirty seconds it did')
    -- AND THE RATE IS THE CONSEQUENCE, WHICH IS MORE THAN 2x BECAUSE THE HEIGHT
    -- MOVED TOO. 170/30 was 5.7 m/s and 225/15 is 15 m/s. That is faster than a
    -- real cargo canopy and it is what was asked for; the band below is wide
    -- enough to say "still a controlled descent" and tight enough to catch a
    -- descentMs somebody has zeroed or a stray order of magnitude.
    local mps = A.altitude / (A.descentMs / 1000.0)
    ok(mps > 12.0 and mps < 20.0,
        ('the crate falls at %.1f m/s, which is a fast canopy rather than a '
         .. 'feather or a rock'):format(mps))
    ok(mps > 170.0 / 30.0 * 2.0,
        ('and more than twice the %.1f m/s it fell at before')
            :format(170.0 / 30.0))

    -- ═══ AND IT FLARES OUT OVER THE LAST 25 FEET (owner, 2026-08-28) ═══
    --
    -- "please make the speed of the air drop a function of it's height - as it
    -- drops the current speed is correct, but as it reaches the ground it should
    -- slow down exponentially to 25% of the current set speed. The final speed
    -- should be achieved roughly 25ft before it touches down."
    --
    -- THREE NUMBERS, AND TWO OF THEM ARE THE OWNER'S VERBATIM. Pinned as
    -- literals for the reason every other number in this block is: they are
    -- somebody's decision rather than a value that drifted.
    eq(A.slowTo, 0.25, 'it lands at a quarter of the cruise rate')
    ok(near(A.slowHeight, 7.62),
        'reached 7.62m up, which is the owner\'s 25 feet in this file\'s units')
    ok(near(A.slowHeight / 0.3048, 25.0, 1e-9),
        ('and 7.62m really is 25ft -- %.4f'):format(A.slowHeight / 0.3048))
    ok((A.slowEFold or 0.0) > 0.0,
        'and the deceleration is spread over a real height rather than stepped')

    -- THE FLARE IS A SMALL PART OF THE DROP, which is the half of the owner's
    -- sentence that is easy to lose: "the current speed is correct" is about
    -- everything above it. At the shipped numbers the final rate is reached with
    -- 3.4% of the altitude left.
    ok(A.slowHeight < A.altitude * 0.1,
        ('the flare is the last %.1f%% of the drop and no more')
            :format(A.slowHeight / A.altitude * 100.0))

    -- ═══ AND IT SLOWED DOWN, 2026-08-23, BY HALF ═══
    --
    -- Owner, after the playtest: cut the Cargobob's speed by 50%. A literal,
    -- because the number it replaced was not a taste setting that drifted -- 90
    -- m/s is 201 mph and a Cargobob does 99.5, so the aircraft was flying at
    -- twice the top speed of the airframe the model was chosen FOR.
    eq(A.planeSpeed, 45.0, 'the Cargobob flies at half what it did')
    local mph = A.planeSpeed * 2.23694
    ok(mph > 90.0 and mph < 110.0,
        ('%.0f mph, which is what the airframe can actually hold -- the 201 mph '
         .. 'it was doing is not a Cargobob'):format(mph))

    -- ═══ AND `planeLeadMs` IS DELIBERATELY NOT COMPENSATED ═══
    --
    -- The run-in lasts planeLeadMs whatever the speed is -- the aircraft is
    -- switched on at tArm and the release is planeLeadMs later -- so halving the
    -- speed shortens the run-in in METRES and not in seconds. Doubling the lead
    -- to hold 1080m would put twelve extra seconds between the arm and the
    -- release, on an arrival the owner has already confirmed as right. This line
    -- is what fails if somebody "restores" the old distance.
    eq(A.planeLeadMs, 12000,
        'and the approach is still twelve seconds long, because that is the '
        .. 'half a slower aircraft does not change')
    local runIn = A.planeSpeed * (A.planeLeadMs / 1000.0)
    ok(near(runIn, 540.0),
        ('so the run-in starts %.0fm out rather than 1080m -- further INSIDE '
         .. 'vehicle draw distance, not outside it'):format(runIn))

    -- ═══ MAX IS 2. HIGH IS 3. THE ENUM IS NOT IN ASCENDING ORDER. ═══
    --
    -- eAudVehiclePriority is NORMAL 0, MEDIUM 1, MAX 2, HIGH 3 -- read off
    -- citizenfx/natives, the file docs.fivem.net renders. A 3 shipped in the
    -- belief that it was the maximum is a HIGH, which is weaker and would look
    -- exactly like the native doing nothing at all. This literal is the only
    -- thing standing between us and that, so it is a literal.
    eq(A.planeAudioPriority, 2,
        'the audio priority is MAX (2), not the higher-looking HIGH (3)')
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
    -- The owner named the number twice. 2026-08-22: "they should be 100
    -- Volts". Then 2026-08-28, after playing with it: "change the volts to 500
    -- on the pickup please". The later one wins, and the earlier is kept here
    -- so the change reads as a decision rather than a drift.
    eq(A.voltsAmount, 500, 'a drop carries 500 Volts')

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
-- PART A -- siting against a WINDOW
-- =========================================================================
--
-- ═══ THE RULE THAT REPLACED "ONE CIRCLE, SOLVED ONCE" (owner, 2026-08-23:
--     "aidrops aren't spawning within the circle at all times") ═══
--
-- A drop is announced at siting and does not fall until somebody walks over,
-- which the blip's ceiling caps at four minutes -- longer than a storm phase. So
-- the landing time is a RANGE, and the margin has to hold across all of it.

describe('siting: every circle, not just one')
do
    local one = { { x = 0.0, y = 0.0, r = 1000.0 } }
    ok(BR.AirdropInside(one, 0.0, 0.0, 250.0), 'the centre clears one circle')
    ok(BR.AirdropInside(one, 750.0, 0.0, 250.0),
        'and so does a point exactly on the margin -- inclusive, as it always was')
    ok(not BR.AirdropInside(one, 750.001, 0.0, 250.0),
        'a millimetre past it does not')

    -- TWO CIRCLES MEANS AND, NEVER OR. A point that satisfies one of them and
    -- not the other is a point the crate could land outside of, which is the
    -- whole failure being fixed.
    local two = {
        { x = 0.0,    y = 0.0, r = 1000.0 },
        { x = 1500.0, y = 0.0, r = 1000.0 },
    }
    ok(BR.AirdropInside(two, 750.0, 0.0, 250.0),
        'a point 250m inside BOTH circles qualifies')
    ok(not BR.AirdropInside(two, 0.0, 0.0, 250.0),
        'the first circle\'s own centre does not, because the second refuses it')
    ok(not BR.AirdropInside(two, 1500.0, 0.0, 250.0),
        'and neither does the second\'s, for the mirror reason')

    -- A CIRCLE NARROWER THAN THE MARGIN REFUSES EVERYTHING, with no early
    -- return doing it -- a distance is never negative.
    ok(not BR.AirdropInside({ { x = 0.0, y = 0.0, r = 100.0 } },
            0.0, 0.0, 250.0),
        'a circle narrower than the margin has no qualifying point at all')

    -- AN EMPTY LIST IS NOT "ANYWHERE", it is a caller bug -- but the only way
    -- to reach one is to build it by hand, and BR.AirdropLandingCircles never
    -- returns fewer than one.
    eq(#BR.AirdropLandingCircles(nil, 0.0, A, 0), 1,
        'a nil storm still yields a circle to be refused by')
    ok(not BR.AirdropInside(BR.AirdropLandingCircles(nil, 0.0, A, 0),
            0.0, 0.0, A.insideBy),
        'and it is radius 0, so no point on the map qualifies without a storm')
end

describe('siting: the window is the gate\'s own deadline')
do
    -- A storm HELD for a day: every instant answers the same circle, so the
    -- window collapses and the only thing left is the count.
    local held = BR.BuildStormRecord(1, 0.0, 0.0, 2000.0,
        0.0, 0.0, 2000.0, 0.0, 24 * 60 * 60 * 1000, 1000, 1.0)

    local atArm = BR.AirdropLandingCircles(held, 0.0, A, 0)
    eq(#atArm, 2, 'at the arm: the landing circle, and the one being shrunk toward')

    local atSite = BR.AirdropLandingCircles(held, 0.0, A, A.blipMaxMs)
    eq(#atSite, 3,
        'at siting: the soonest landing, the latest one the gate allows, and the next circle')

    -- THE TWO ENDPOINTS BOUND EVERYTHING BETWEEN THEM, and that is convexity
    -- rather than sampling: inside one published record the centre and the
    -- radius are both LINEAR in time, so |P - C(t)| - r(t) is convex and a
    -- convex function that is <= 0 at both ends is <= 0 across the interval.
    -- This drives a real shrink and checks the claim at a hundred instants.
    local shrinking = BR.BuildStormRecord(2, 0.0, 0.0, 2000.0,
        900.0, 0.0, 800.0, 0.0, 0, 600000, 1.0)
    local flight = (A.planeLeadMs or 0) + A.descentMs
    local circles = BR.AirdropLandingCircles(shrinking, 0.0, A, 300000)

    local held2 = true
    for _, p in ipairs({ { x = 700.0, y = 0.0 }, { x = 900.0, y = 0.0 },
                         { x = 800.0, y = 100.0 }, { x = 300.0, y = 0.0 } }) do
        if BR.AirdropInside(circles, p.x, p.y, A.insideBy) then
            for i = 0, 100 do
                local t = flight + (300000 * i / 100)
                local cx, cy, r = BR.StormAt(shrinking, t)
                if BR.Dist(p.x, p.y, cx, cy) > r - A.insideBy then
                    held2 = false
                end
            end
        end
    end
    ok(held2,
        'a point that clears both ends of the window clears every instant in it')
end

describe('siting: the owner\'s "only spawn within the NEXT circle"')
do
    -- ═══ AND WHY IT IS A SEPARATE CHECK RATHER THAN A CONSEQUENCE ═══
    --
    -- If circles nested -- |C1 - C0| <= r0 - r1 -- then "inside the next circle"
    -- would imply "inside every circle on the way to it" and one check would do.
    -- config/storm.lua's BREAKOUT is exactly the rule that breaks that (owner,
    -- 2026-08-06: "this will force ALL players to move"), so both are asked.
    local broken = BR.BuildStormRecord(3, 0.0, 0.0, 2000.0,
        1500.0, 0.0, 800.0, 0.0, 600000, 600000, 1.0)
    ok(BR.Dist(0.0, 0.0, 1500.0, 0.0) > 2000.0 - 800.0,
        'this storm record is a genuine breakout: the next circle is not nested')

    -- Holding, so the landing circle is the CURRENT one at both ends of the
    -- window and only the next-circle check can refuse anything.
    local circles = BR.AirdropLandingCircles(broken, 0.0, A, A.blipMaxMs)
    ok(BR.AirdropInside({ circles[1] }, 0.0, 0.0, A.insideBy),
        'the current circle is perfectly happy with its own centre')
    ok(not BR.AirdropInside(circles, 0.0, 0.0, A.insideBy),
        'and the whole rule refuses it, because the storm is leaving')
    ok(BR.AirdropInside(circles, 1500.0, 0.0, A.insideBy),
        'a point 250m inside both is what survives')

    -- ...AND IT IS THE POI FILTER THAT CHANGES, not just a predicate.
    local pois = {
        { id = 'stay', x = 1500.0, y = 0.0 },
        { id = 'left', x = 0.0,    y = 0.0 },
    }
    local got = BR.AirdropSitesIn(pois, circles, A.insideBy, nil)
    eq(#got, 1, 'one of the two POIs qualifies')
    eq(got[1].id, 'stay', 'and it is the one the storm is moving toward')
end

-- =========================================================================
-- PART A -- the payout
-- =========================================================================

describe('payout')
do
    local items = BR.AirdropPayout(BR.Rng(7), A)
    ok(#items >= A.minItems and #items <= A.maxItems,
        ('a drop holds between %d and %d items'):format(A.minItems, A.maxItems),
        #items)

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

describe('payout: 10 to 14, drawn per drop')
do
    -- Owner, 2026-08-22: "instead of 'up to 12' items, let's make it 10-14
    -- items in these airdrops. That should be enough for an entire squad."
    --
    -- IT WAS A FIXED TWELVE. The count is a draw now, and these are the three
    -- things that has to keep being true: it stays inside the range, it is
    -- deterministic for a seed, and it actually VARIES -- a "range" that always
    -- pays the same number is the bug this would most plausibly ship with.
    local counts, lo, hi = {}, math.huge, -math.huge
    for seed = 1, 400 do
        local n = #BR.AirdropPayout(BR.Rng(seed), A)
        counts[n] = (counts[n] or 0) + 1
        if n < lo then lo = n end
        if n > hi then hi = n end
    end
    eq(lo, A.minItems, 'the smallest drop across 400 seeds is the minimum')
    eq(hi, A.maxItems, 'and the largest is the maximum')

    -- EVERY VALUE IN THE RANGE IS REACHABLE. An off-by-one in the draw would
    -- leave one end unvisited and nothing else here would notice.
    local missing = {}
    for n = A.minItems, A.maxItems do
        if not counts[n] then missing[#missing + 1] = n end
    end
    eq(#missing, 0, 'and every count in between actually happens',
        table.concat(missing, ', '))

    -- Deterministic, which is the contract the whole layout has.
    eq(#BR.AirdropPayout(BR.Rng(77), A), #BR.AirdropPayout(BR.Rng(77), A),
        'the same seed draws the same count')

    -- ═══ THE COUNT COMES OFF THE AIRDROP'S OWN STREAM ═══
    --
    -- docs/match-math.md section 1 gives every subsystem a prime of its own so
    -- one subsystem's draws cannot shift another's. This function is handed an
    -- rng and must use THAT one and no other -- a draw taken from the loot
    -- stream would move every downstream loot draw and silently change every
    -- layout on the map.
    --
    -- Proved by handing it an rng that counts how often it is asked, and
    -- checking the global generator is untouched.
    local asks = 0
    local real = BR.Rng(5)
    local counting = {
        int     = function(_, a, b) asks = asks + 1 return real:int(a, b) end,
        float   = function() asks = asks + 1 return real:float() end,
        shuffle = function(_, t) asks = asks + 1 return real:shuffle(t) end,
        pick    = function(_, t) asks = asks + 1 return real:pick(t) end,
    }
    local out = BR.AirdropPayout(counting, A)
    ok(#out >= A.minItems, 'a payout came out of the rng it was given')
    ok(asks > 0, 'and every draw went through it')

    -- THE COUNT IS DRAWN BEFORE ANY DECK IS SHUFFLED, so neither can move the
    -- other. The first ask is the count.
    local firstWasInt = false
    local probe = {
        int = function(_, a, b) firstWasInt = true return BR.Rng(9):int(a, b) end,
        float = function() return 0.0 end,
        shuffle = function() end,
        pick = function(_, t) return t[1] end,
    }
    BR.AirdropPayout(probe, A)
    ok(firstWasInt, 'the count is an int draw, taken first')

    -- A CONFIG PINNED TO ONE COUNT BURNS NO DRAW AT ALL (Rng:int returns early
    -- when hi <= lo), so the old fixed-count behaviour is still reachable byte
    -- for byte from one config line. Worth pinning: it is the escape hatch if
    -- the owner wants a fixed number back.
    local fixed = { payout = A.payout, resolvedPools = A.resolvedPools,
                    minItems = 12, maxItems = 12 }
    eq(#BR.AirdropPayout(BR.Rng(31), fixed), 12,
        'minItems == maxItems pays exactly that many')

    -- CLAMPED TO THE ARRAY. A maxItems above #payout would ask for slots that
    -- do not exist and quietly pay fewer items than the config claims.
    local pool = { p = { { item = 'x', kind = 'consumable', rarity = 1, count = 1 },
                         { item = 'y', kind = 'consumable', rarity = 1, count = 1 } } }
    local greedy = { payout = { 'p', 'p' }, minItems = 5, maxItems = 9,
        resolvedPools = pool }
    eq(#BR.AirdropPayout(BR.Rng(3), greedy), 2,
        'a range longer than the array is clamped to the array')

    -- ...AND THE CLAMP IS ON THE DRAW, NOT JUST ON THE LOOP. A `for i = 1, n`
    -- over a short array already stops at the end of it, so an unclamped `hi`
    -- yields the same ITEMS -- and burns a different rng draw doing it, which
    -- silently shifts everything the same generator hands out afterwards. The
    -- only way to see that from outside is to compare against the config the
    -- clamp is supposed to produce.
    local clamped = { payout = { 'p', 'p' }, minItems = 2, maxItems = 2,
        resolvedPools = pool }
    -- ACROSS MANY SEEDS, because the deck here is two cards: a single seed
    -- agrees by coin flip about half the time, which is a test that passes for
    -- the wrong reason half the time it is run.
    local identical = true
    for seed = 1, 60 do
        local g = BR.AirdropPayout(BR.Rng(seed), greedy)
        local c = BR.AirdropPayout(BR.Rng(seed), clamped)
        if #g ~= #c then identical = false break end
        for i = 1, #g do
            if g[i].item ~= c[i].item then identical = false break end
        end
        if not identical then break end
    end
    ok(identical,
        'a clamped range consumes exactly the rng the equivalent config does -- '
        .. 'an unclamped draw would burn an extra number and deal differently')

    -- ...and a range the wrong way round does not produce a negative count.
    local backwards = { payout = { 'p', 'p', 'p' }, minItems = 3, maxItems = 1,
        resolvedPools = greedy.resolvedPools }
    local n = #BR.AirdropPayout(BR.Rng(3), backwards)
    ok(n >= 0 and n <= 3, 'a backwards range still pays a sane count', n)
end

describe('payout: the airdrop count does not move the loot map')
do
    -- THE PROPERTY docs/match-math.md SECTION 1 EXISTS FOR, checked rather than
    -- asserted. Drawing the item count added an rng call to the airdrop stream;
    -- if it had been taken from the loot stream instead, every layout in the
    -- game would have shifted the day this shipped -- silently, because a
    -- different-but-valid layout looks exactly like a correct one.
    local seed = 20260822
    local before = BR.BuildLootLayout and BR.BuildLootLayout(seed) or nil
    if before then
        -- Burn a whole airdrop payout off a SEPARATE stream, as the server does.
        BR.AirdropPayout(BR.Rng(seed + 1299709), A)
        local after = BR.BuildLootLayout(seed)
        eq(#after, #before, 'the same seed still lays out the same item count')
        local same = true
        for i = 1, #before do
            if before[i].item ~= after[i].item
               or before[i].x ~= after[i].x or before[i].y ~= after[i].y then
                same = false
                break
            end
        end
        ok(same, 'and the same items in the same places')
    else
        -- NOT A SILENT SKIP. If the generator ever stops being loaded here this
        -- fails rather than quietly passing, because a test that can no longer
        -- see what it guards is not a passing test.
        ok(false, 'BR.BuildLootLayout is not loaded -- this guard is blind')
    end
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
    ok(near(BR.AirdropHeightAt(rec, 31000.0), 0.0), 'and on the ground at tLand')

    -- ═══ AND HALFWAY THROUGH THE SECONDS IS NO LONGER HALFWAY DOWN THE METRES
    --     (owner, 2026-08-28) ═══
    --
    -- This line used to read 130.0. The crate now spends nearly all of the fall
    -- at the cruise rate and the last stretch at a quarter of it, so by the
    -- midpoint of the clock it is well past the midpoint of the drop -- which is
    -- the entire visible difference and is what BR.AirdropProgress and
    -- BR.AirdropFallen being two different questions means in metres.
    local mid = BR.AirdropHeightAt(rec, 16000.0)
    ok(mid < 130.0 and mid > 100.0,
        ('halfway through the fall it is %.1fm up, BELOW the 130m a linear '
         .. 'descent would be at'):format(mid))

    ok(not BR.AirdropLanded(rec, 30999.0), 'not landed a millisecond early')
    ok(BR.AirdropLanded(rec, 31000.0), 'landed at tLand')

    -- A zero-length descent (reachable only from the dev command) must resolve
    -- rather than divide by zero.
    local instant = BR.BuildAirdropRecord(1, poi, 260.0, 5000.0, 5000.0, 0.0)
    ok(near(BR.AirdropProgress(instant, 5000.0), 1.0),
        'a zero-span descent is already over')
end

describe('descent: the flare')
do
    -- ═══ "PLEASE MAKE THE SPEED OF THE AIR DROP A FUNCTION OF IT'S HEIGHT - AS
    --     IT DROPS THE CURRENT SPEED IS CORRECT, BUT AS IT REACHES THE GROUND IT
    --     SHOULD SLOW DOWN EXPONENTIALLY TO 25% OF THE CURRENT SET SPEED. THE
    --     FINAL SPEED SHOULD BE ACHIEVED ROUGHLY 25FT BEFORE IT TOUCHES DOWN."
    --     (owner, 2026-08-28) ═══
    --
    -- Four claims and four groups of assertions: the cruise rate is the one that
    -- was already confirmed and is untouched, the final rate is a quarter of it,
    -- that rate arrives 25 feet up and is held from there, and the whole thing is
    -- still arithmetic over a published record and a clock.
    --
    -- MEASURED, NOT READ BACK OFF THE SHAPE. Everything below walks the fall a
    -- millisecond at a time through the same two functions the client calls, so
    -- these are statements about the curve rather than about the algebra that
    -- produced it.
    local poi = { id = 'x', x = 0.0, y = 0.0, z = 0.0 }
    local rec = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, poi, A.altitude, 0.0, 0.0), 0.0, A)
    local span  = rec.tLand - rec.tRelease
    local V     = A.altitude * 1000.0 / A.descentMs        -- the cruise rate
    local final = V * A.slowTo

    -- ─── 1. THE CURRENT SPEED IS STILL THE CURRENT SPEED ───
    --
    -- The rate the owner confirmed on 2026-08-23 is `altitude / descentMs`, and
    -- holding it is the entire reason the fall got longer instead of the early
    -- part getting faster. This is the assertion that fails if somebody ever
    -- pays for the tail out of the cruise.
    ok(near(V, 15.0), ('the cruise rate is %.2f m/s'):format(V))
    ok(near(BR.AirdropSpeedAt(rec, rec.tRelease, A), V, 1e-6),
        'and the crate leaves the aircraft at exactly that',
        ('%.9f'):format(BR.AirdropSpeedAt(rec, rec.tRelease, A)))
    -- ...AND THE EARLY FALL IS THE OLD FALL, TO THE MILLIMETRE. One second after
    -- the release it has dropped V metres and no more, which is what "as it
    -- drops the current speed is correct" means when it is turned into a number.
    ok(near(BR.AirdropHeightAt(rec, rec.tRelease + 1000.0, A),
            A.altitude - V, 1e-6),
        'one second in it has fallen exactly the cruise rate, as it always did')
    ok(near(BR.AirdropHeightAt(rec, rec.tRelease + 10000.0, A),
            A.altitude - V * 10.0, 0.01),
        'and ten seconds in it is still within a centimetre of the old line')

    -- ─── 2. A QUARTER OF IT AT TOUCHDOWN ───
    local vDown = BR.AirdropSpeedAt(rec, rec.tLand, A)
    ok(near(vDown, final, 1e-9),
        ('it touches down at %.4f m/s'):format(vDown))
    ok(near(vDown / BR.AirdropSpeedAt(rec, rec.tRelease, A), A.slowTo, 1e-9),
        'which is 25% of the speed it left at, which is the ratio that was asked '
        .. 'for rather than a number that happens to be small')

    -- ─── 3. REACHED 25 FEET UP, AND HELD FROM THERE ───
    --
    -- Walked at 1ms, so the height reported is the first sample at or under the
    -- boundary rather than the boundary itself -- hence the 2cm band, which is
    -- one millisecond of travel at the final rate and nothing else.
    local hReached, tReached = nil, nil
    local prevH, prevV = A.altitude + 1.0, V + 1.0
    local monotone, inBand = true, true
    local t = rec.tRelease
    while t <= rec.tLand do
        local h = BR.AirdropHeightAt(rec, t, A)
        local v = BR.AirdropSpeedAt(rec, t, A)
        -- NEVER FASTER THAN THE CRUISE AND NEVER SLOWER THAN THE FINAL RATE. An
        -- exponential written the wrong way round overshoots one end or the
        -- other, and a crate that briefly falls at 40 m/s reads as a dropped
        -- frame rather than as a bug.
        if v > V + 1e-9 or v < final - 1e-9 then inBand = false end
        -- AND IT ONLY EVER SLOWS. Both curves are monotone, which is what stops
        -- a mis-signed exponent producing a crate that hesitates or rises.
        if h > prevH + 1e-9 or v > prevV + 1e-9 then monotone = false end
        prevH, prevV = h, v
        if not hReached and v <= final * (1.0 + 1e-9) then
            hReached, tReached = h, t
        end
        t = t + 1.0
    end
    ok(monotone, 'the crate only ever falls, and only ever slows down')
    ok(inBand, 'never faster than the cruise rate, never slower than the final one')
    ok(hReached ~= nil and near(hReached, A.slowHeight, 0.02),
        ('the final rate is reached %.2fm up -- %.1f feet, which is the owner\'s '
         .. '25'):format(hReached or -1.0, (hReached or 0.0) / 0.3048))

    -- HELD, not merely touched. The last 25 feet are a straight line at the
    -- final rate, which is what "the final speed should be ACHIEVED roughly 25ft
    -- before it touches down" says about the 25 feet after it.
    local held, straight = true, true
    for tt = tReached, rec.tLand, 1.0 do
        if not near(BR.AirdropSpeedAt(rec, tt, A), final, 1e-9) then
            held = false
        end
        if not near(BR.AirdropHeightAt(rec, tt, A),
                    hReached - final * (tt - tReached) / 1000.0, 1e-6) then
            straight = false
        end
    end
    ok(held, 'and held at it for every millisecond of the rest of the fall')
    ok(straight, 'so the last 25 feet are a straight line, not a decaying tail')
    ok(near((rec.tLand - tReached) / 1000.0, A.slowHeight / final, 0.01),
        ('which takes %.2fs'):format((rec.tLand - tReached) / 1000.0))

    -- ...AND NOTHING VISIBLE HAPPENS ABOVE THE FLARE'S OWN NEIGHBOURHOOD. The
    -- owner asked for a change "as it reaches the ground", so the deceleration
    -- has to be confined to the bottom of the drop rather than smeared over it.
    local hNinety = nil
    for tt = rec.tRelease, rec.tLand, 1.0 do
        if BR.AirdropSpeedAt(rec, tt, A) < V * 0.9 then
            hNinety = BR.AirdropHeightAt(rec, tt, A)
            break
        end
    end
    ok(hNinety ~= nil and hNinety < 30.0 and hNinety > A.slowHeight,
        ('it is still doing 90%% of the cruise rate at %.1fm, so the whole flare '
         .. 'is the last %.0f metres'):format(hNinety or -1.0, hNinety or 0.0))

    -- ─── 4. AND THE TOTAL IS DERIVED, WHICH IS WHERE THE TIME WENT ───
    --
    -- 14.492s of cruise above the flare, 0.704s of exponential tail, 2.032s of
    -- flare. Nothing anywhere writes 17228 down; this is the number falling out
    -- of the three config values, and it is pinned here so that a change to any
    -- of them is a change somebody has to look at.
    ok(near(span, BR.AirdropFallMs(A), 1e-6),
        'the record\'s own span is BR.AirdropFallMs')
    ok(near(span, 17228.24, 0.01),
        ('and the fall takes %.3fs rather than the %.3fs of cruise it is built '
         .. 'from'):format(span / 1000.0, A.descentMs / 1000.0))
    ok(span > A.descentMs and span < A.descentMs * 1.25,
        ('which is %.0fms longer -- a tail, not a different drop')
            :format(span - A.descentMs))

    -- BOTH ENDS ARE EXACT, which is the property that lets the client keep
    -- drawing a crate straight off `tLand` with no landing tolerance anywhere.
    ok(near(BR.AirdropHeightAt(rec, rec.tRelease, A), A.altitude),
        'it leaves at the full release altitude')
    ok(near(BR.AirdropHeightAt(rec, rec.tLand, A), 0.0),
        'and is exactly on the ground at tLand, with nothing left over')

    -- ─── AND IT IS STILL A PURE FUNCTION OF TIME SINCE THE RELEASE ───
    --
    -- ═══ THE ONE PROPERTY THE WHOLE DESIGN RESTS ON ═══
    --
    -- The crate is a LOCAL, non-networked object on every client and there is no
    -- position on the wire. That only works while its height is decided by
    -- arithmetic over the published record and the synced clock -- so the curve
    -- may read the elapsed time, the altitude and the config, and nothing else.
    -- A second record with a different place, bearing, announcement and release
    -- must draw exactly the same fall.
    local elsewhere = BR.BuildAirdropRecord(9,
        { id = 'y', x = -4000.0, y = 900.0, z = 512.0 },
        A.altitude, 777000.0, 777000.0 + 61234.0 + span, 213.0,
        777000.0 + 61234.0)
    local pure = true
    for e = 0, math.floor(span), 97 do
        if not near(BR.AirdropHeightAt(rec, rec.tRelease + e, A),
                    BR.AirdropHeightAt(elsewhere, elsewhere.tRelease + e, A),
                    1e-9) then
            pure = false
        end
    end
    ok(pure, 'two drops at two places on two clocks fall identically, which is '
        .. 'what lets the crate stay off the wire')

    -- NO STATE, EITHER. Asking out of order, or twice, must not move the answer
    -- -- a stepped integration would pass every assertion above and fail this
    -- one, and it is the shape a "physics" descent would arrive as.
    local stateless = true
    local first = BR.AirdropHeightAt(rec, rec.tRelease + 9000.0, A)
    for _, at in ipairs({ span, 0.0, span * 0.5, 1.0, span - 1.0, 9000.0 }) do
        BR.AirdropHeightAt(rec, rec.tRelease + at, A)
        if BR.AirdropHeightAt(rec, rec.tRelease + 9000.0, A) ~= first then
            stateless = false
        end
    end
    ok(stateless, 'and asking for the same instant twice gives the same answer, '
        .. 'whatever was asked in between')

    -- ─── AND THE LINEAR FALL IS STILL REACHABLE FROM ONE CONFIG LINE ───
    --
    -- A cfg with no `slowTo` is the pre-2026-08-28 descent exactly: no stretch,
    -- no flare, halfway through is halfway down. That is what makes the flare a
    -- thing that was added rather than a thing that was baked in.
    local flat = { descentMs = A.descentMs, altitude = A.altitude }
    ok(near(BR.AirdropFallShape(A.altitude, flat).total, 1.0),
        'without slowTo the fall is not stretched at all')
    ok(near(BR.AirdropFallMs(flat), A.descentMs),
        'so BR.AirdropFallMs is descentMs, exactly as it was')
    local lin = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, poi, A.altitude, 0.0, 0.0), 0.0, flat)
    ok(near(BR.AirdropHeightAt(lin, lin.tRelease + A.descentMs / 2, flat),
            A.altitude / 2),
        'and it is a straight line again, halfway down halfway through')
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

describe('the 200m gate: how far the closest player is')
do
    -- Owner, 2026-08-22: "measured by the distance between the drop (at ground
    -- level) and the closest player".
    --
    -- ═══ GROUND LEVEL TO GROUND LEVEL, WHICH IS WHY z IS NOT IN IT ═══
    --
    -- A crate 260m up is 260m from somebody standing directly underneath it, so
    -- a gate that counted the altitude would be gating on how high the plane
    -- flies rather than on how far anybody has to walk -- and at the committed
    -- 260m altitude and 200m threshold it would never open at all.
    eq(BR.AirdropClosest({ { x = 100.0, y = 0.0 } }, 0.0, 0.0), 100.0,
        'one player, one distance')
    eq(BR.AirdropClosest({
        { x = 900.0, y = 0.0 }, { x = 40.0, y = 0.0 }, { x = 300.0, y = 0.0 },
    }, 0.0, 0.0), 40.0, 'the CLOSEST of several, not the first or the last')

    local far = BR.AirdropClosest({ { x = 0.0, y = 0.0, z = 5000.0 } }, 0.0, 0.0)
    eq(far, 0.0, 'a player 5km STRAIGHT UP is zero metres away on the ground')

    -- NOBODY IS NOT ZERO. An empty list has to be "infinitely far", because a
    -- zero would open the gate for a match with no players in it -- which is
    -- precisely the case the whole feature exists to refuse.
    eq(BR.AirdropClosest({}, 0.0, 0.0), math.huge, 'nobody is infinitely far')
    eq(BR.AirdropClosest(nil, 0.0, 0.0), math.huge, 'and so is no list at all')

    -- A MALFORMED ENTRY IS SKIPPED, NOT COUNTED AS THE ORIGIN. (0, 0) is a real
    -- place on this map -- it is in the ocean south-west of Los Santos, but a
    -- POI near it would have its gate opened by a player with no position.
    eq(BR.AirdropClosest({ { x = nil, y = nil }, { x = 10.0, y = 0.0 } },
        0.0, 0.0), 10.0, 'a player with no position is skipped, not placed at 0,0')
    eq(BR.AirdropClosest({ {} }, 0.0, 0.0), math.huge,
        'and a list of nothing but those is still nobody')

    -- The threshold itself is the owner's number and is pinned so a retune has
    -- to be deliberate.
    eq(A.armWithin, 200.0, 'the gate is the owner\'s 200 metres')
    ok(A.planeViewRadius == nil,
        'and the client-side view radius it replaced is GONE rather than left '
        .. 'as a second gate on an answered question')
end

describe('descent: the blip window')
do
    -- ═══ THE OWNER'S NEW RULE, WHICH HAS TWO BRANCHES AND A CHANGE OF ORIGIN ═══
    --
    -- 2026-08-22: "we keep the blip on until 1 minute after the crate is opened,
    -- or no longer than 4 minutes if unopened, which would also be the case if
    -- nobody got to the location in time."
    --
    -- The old rule was one minute after tLAND. The ceiling is measured from
    -- tSTART, because the whole span -- announcement, run-in, fall, search -- is
    -- time the owner spent not knowing where to go.
    local poi = { id = 'x', x = 0.0, y = 0.0, z = 0.0 }
    -- Announced at 1000, on the ground at 31000. A minute after the open, four
    -- minutes from the announcement.
    local cfg = { blipAfterOpenMs = 60000, blipMaxMs = 240000 }
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)

    ok(not BR.AirdropBlipVisible(rec, 999.0, cfg),
        'nothing on the map before the drop is announced')
    ok(BR.AirdropBlipVisible(rec, 1000.0, cfg), 'up the moment it is announced')
    ok(BR.AirdropBlipVisible(rec, 31000.0, cfg), 'still up as it lands')

    -- ─── NEVER OPENED: the ceiling, and it is the branch that matters most ───
    --
    -- The same playtest deleted the auto-open, so a crate nobody reaches is
    -- never opened at all and `tOpen` is never set. Without this ceiling the
    -- blip would mark the map for the rest of the match.
    ok(BR.AirdropBlipVisible(rec, 91000.0, cfg),
        'still up a minute after landing, which the OLD rule ended at')
    ok(BR.AirdropBlipVisible(rec, 241000.0, cfg),
        'and still up at exactly four minutes from the announcement')
    ok(not BR.AirdropBlipVisible(rec, 241001.0, cfg),
        'and gone a millisecond later')
    eq(BR.AirdropBlipEndsAt(rec, cfg), 241000.0,
        'the unopened window ends at tStart + blipMaxMs')

    -- ─── OPENED: one minute from the open, and it SHORTENS the window ───
    local opened = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)
    opened.tOpen = 41000.0            -- ten seconds after it landed
    eq(BR.AirdropBlipEndsAt(opened, cfg), 101000.0,
        'an opened drop ends a minute after the open, not after the landing')
    ok(BR.AirdropBlipVisible(opened, 101000.0, cfg), 'up to that instant')
    ok(not BR.AirdropBlipVisible(opened, 101001.0, cfg), 'and not past it')
    -- THE SHORTENING IS THE INTENT, NOT AN OVERSIGHT. The blip exists to get
    -- somebody there; once somebody is there it has a minute of work left.
    ok(BR.AirdropBlipEndsAt(opened, cfg) < BR.AirdropBlipEndsAt(rec, cfg),
        'so opening it early ends the blip EARLIER than the four-minute cap')

    -- A crate opened at 3m55 keeps its blip five seconds past the nominal
    -- ceiling, because the owner's sentence attaches the 4 minutes to
    -- "if unopened". Pinned so nobody "fixes" it into a min().
    local late = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)
    late.tOpen = 236000.0
    eq(BR.AirdropBlipEndsAt(late, cfg), 296000.0,
        'a late open runs past the cap rather than being clipped by it')

    ok(not BR.AirdropBlipVisible(nil, 5000.0, cfg), 'no record, no blip')
    eq(BR.AirdropBlipEndsAt(nil, cfg), 0.0, 'and no record ends at zero')

    -- DEFAULTS, because the client passes the whole config table and a config
    -- missing a key must not silently mean "never expires" or "expires now".
    local bare = BR.BuildAirdropRecord(1, poi, 260.0, 0.0, 30000.0, 0.0)
    eq(BR.AirdropBlipEndsAt(bare, nil), 240000.0,
        'no config falls back to the four-minute ceiling')
    bare.tOpen = 1000.0
    eq(BR.AirdropBlipEndsAt(bare, nil), 61000.0,
        'and to the one-minute post-open window')
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

describe('the plane: the flyover and the release are ONE instant, at any speed')
do
    -- ═══ THE FIRST THING TO RULE OUT FOR "THE DELAY BETWEEN WHEN THE CARGOBOB
    --     FLIES OVER AND WHEN THE CARGO DROPS" (owner, 2026-08-23) ═══
    --
    -- `planeSpeed` was halved from 90 to 45 on the same day and `planeLeadMs` was
    -- deliberately not compensated. This is the block that says what that could
    -- and could not have done, as arithmetic rather than as a paragraph.
    local poi = { id = 'x', x = 500.0, y = -300.0, z = 20.0 }
    local rec = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, poi, A.altitude, 0.0, 37.0), 0.0, A)

    for _, speed in ipairs({ 22.5, 45.0, 90.0, 180.0 }) do
        local cfg = {
            planeSpeed = speed, planeAltAbove = A.planeAltAbove,
            planeLeadMs = A.planeLeadMs, planeTrailMs = A.planeTrailMs,
        }
        local px, py = BR.AirdropPlaneAt(rec, rec.tRelease, cfg)
        ok(near(px, rec.x, 1e-6) and near(py, rec.y, 1e-6),
            ('at %.1f m/s the aircraft is over the drop point at tRelease')
                :format(speed), ('%.4f, %.4f'):format(px, py))

        -- ...AND THE RUN-IN IS THE SAME NUMBER OF SECONDS. Speed decides where
        -- the approach STARTS, never when it ends: the aircraft is switched on
        -- at tArm and BR.AirdropPlaneAt puts it over the point planeLeadMs
        -- later. That is why halving it needed no compensation, and why it
        -- cannot be the cause of a late crate.
        local sx, sy = BR.AirdropPlaneAt(rec, rec.tArm, cfg)
        ok(near(BR.Dist(sx, sy, rec.x, rec.y),
                speed * (A.planeLeadMs / 1000.0), 1e-3),
            ('and it starts %.0fm out, which is the only thing speed moves')
                :format(speed * (A.planeLeadMs / 1000.0)))
    end

    -- THE CRATE LEAVES ON THE SAME MILLISECOND, which is the other half of the
    -- owner's sentence. There is one timestamp and both read it.
    ok(BR.AirdropReleased(rec, rec.tRelease), 'the crate is away at tRelease')
    ok(not BR.AirdropReleased(rec, rec.tRelease - 1), 'and aboard a millisecond before')
    ok(near(BR.AirdropProgress(rec, rec.tRelease), 0.0),
        'with the whole fall still ahead of it')
    ok(near(BR.AirdropHeightAt(rec, rec.tRelease), A.altitude),
        'at the full release altitude')

    -- AND THE AIRCRAFT IS EXACTLY `planeAltAbove` ABOVE THE BOX AT THAT INSTANT.
    -- Both are heights above the SAME ground -- the drop point's -- so the gap
    -- between them is one config value and nothing else.
    local _, _, paz = BR.AirdropPlaneAt(rec, rec.tRelease, A)
    ok(near(paz - BR.AirdropHeightAt(rec, rec.tRelease), A.planeAltAbove),
        'and the box leaves exactly planeAltAbove beneath it')
end

describe('the plane: one height, solved from the map file, for the whole pass')
do
    -- ═══ THE SECOND ATTEMPT AT "MAKE SURE THE CARGOBOB AVOIDS TERRAIN, BECAUSE
    --     DROPS AT CHILI[AD]" ═══
    --
    -- Owner, 2026-08-23, on 56c0ba7 -- which already had the first: "it's
    -- definitely still doing that... get the Z for each coord where the drop is
    -- happening, fly the cargobob 250m above that".
    --
    -- WHAT THE FIRST ATTEMPT'S TESTS PROVED, AND WHY THEY PASSED ANYWAY. They
    -- asserted the corridor's SHAPE -- eight samples, forward of the aircraft,
    -- collapsing onto the drop point at tRelease, opening out on the trail --
    -- and every one of those was true. What no pure test could reach is that
    -- GetGroundZFor_3dCoord only answers for terrain the client has streamed,
    -- so the corridor was asking about ground up to 810m from the only player
    -- the drop is guaranteed to have, and the clip meant the one stretch it
    -- COULD see was the one with nothing to clear. The shape was right and the
    -- answer was always nil.
    --
    -- SO THE CASES BELOW ARE THE SAME QUESTIONS ASKED OF A MODEL THAT CANNOT
    -- ANSWER nil: the height comes out of BR.Config.Map.POIs, which is in
    -- memory. Every assertion the corridor block made has an heir here, and
    -- three of them are now checked against the REAL map table rather than a
    -- constructed record.
    local poi = { id = 'chiliad_e', x = 1150.0, y = 5350.0, z = 160.0 }
    local rec = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, poi, A.altitude, 0.0, 270.0), 0.0, A)

    -- UPWARD ONLY, AND NEVER DOWNWARD. The flight plan is a floor of its own:
    -- an aircraft that dipped into a valley would arrive under the crate's
    -- release height, which is the record's business and not the terrain's.
    -- Unchanged from the corridor version -- BR.AirdropPlaneZ survived the
    -- rework because taking the higher of two numbers was never the broken part.
    eq(BR.AirdropPlaneZ(355.0, nil, 60.0), 355.0,
        'nothing under the route means the nominal height')
    eq(BR.AirdropPlaneZ(355.0, 10.0, 60.0), 355.0,
        'ground far below it changes nothing')
    eq(BR.AirdropPlaneZ(355.0, 780.0, 60.0), 840.0,
        'and the Chiliad summit lifts it to 60m over the rock')
    eq(BR.AirdropPlaneZ(355.0, 295.0, 60.0), 355.0,
        'a ridge exactly at the clearance is not a lift')

    -- ═══ THE FLIGHT LINE COVERS THE WHOLE PASS, BOTH SIDES OF THE DROP ═══
    --
    -- The corridor deliberately forgot the ground behind the aircraft, which was
    -- right for a floor recomputed every frame and wrong for one solved once.
    -- And it only reached the trail by accident: the Cargobob flies on for
    -- planeTrailMs after the release -- 675m, FURTHER than the 540m run-in --
    -- so half the exposure was past the drop point the whole time.
    local x1, y1, x2, y2 = BR.AirdropRunIn(rec, A)
    ok(near(BR.Dist(x1, y1, rec.x, rec.y),
            A.planeSpeed * (A.planeLeadMs / 1000.0), 1e-3),
        'the line starts where the run-in starts, 540m back')
    ok(near(BR.Dist(x2, y2, rec.x, rec.y),
            A.planeSpeed * (A.planeTrailMs / 1000.0), 1e-3),
        'and ends where the trail ends, 675m on -- further than the run-in')
    local sx, sy = BR.AirdropPlaneAt(rec, rec.tArm, A)
    ok(near(sx, x1, 1e-6) and near(sy, y1, 1e-6),
        'and its near end is exactly where BR.AirdropPlaneAt builds the aircraft')

    -- ═══ AND WHAT IS UNDER IT COMES OUT OF THE AUTHORED TABLE ═══
    local one = { { id = 'peak', x = rec.x, y = rec.y, z = 700.0, radius = 50.0 } }
    local top, id = BR.AirdropRunInTop(rec, one, A)
    eq(top, 700.0, 'a POI on the line is found')
    eq(id, 'peak', 'and named, which is what /brairdrop prints')

    -- OFF THE BEARING IS NOT A LIFT. A summit half a kilometre to the side is
    -- not something this aircraft flies through, and lifting for it would make
    -- the feature the permanent altitude increase it must never become.
    local a = math.rad(rec.heading)
    local rx, ry = math.cos(a), math.sin(a)   -- the flight line's own right
    local side = { { id = 'aside', x = rec.x + rx * 900.0,
                     y = rec.y + ry * 900.0, z = 700.0, radius = 50.0 } }
    eq(BR.AirdropRunInTop(rec, side, A), nil,
        'a summit 900m off the bearing is not under the route')

    -- ...AND BEHIND THE AIRCRAFT STILL COUNTS, which is the case the corridor
    -- could not see at all: the height is chosen before takeoff, so it has to
    -- cover ground the aircraft has not reached yet AND ground it starts over.
    local behindX, behindY = BR.AirdropPlaneAt(rec, rec.tArm, A)
    local behind = { { id = 'start', x = behindX, y = behindY, z = 700.0,
                       radius = 50.0 } }
    eq(BR.AirdropRunInTop(rec, behind, A), 700.0,
        'the ground the run-in begins over is under the route too')

    ok(BR.AirdropRunInTop(nil, BR.Config.Map.POIs, A) == nil,
        'no record, no answer')
    ok(BR.AirdropRunInTop(rec, nil, A) == nil,
        'and no table, no answer -- never a zero, which would be sea level')

    -- ═══ THE HEIGHT ITSELF, AGAINST THE REAL MAP ═══
    --
    -- These three are the whole feature, and they are checked against
    -- BR.Config.Map.POIs rather than a fixture -- so a POI edited into or out of
    -- the massif changes the answer here rather than in a playtest.
    local P = BR.Config.Map.POIs
    local function poiById(want)
        for _, p in ipairs(P) do if p.id == want then return p end end
    end

    -- FLAT GROUND IS NOT A LIFT. lsia is at z 20 with nothing high anywhere
    -- near it, so the aircraft flies exactly planeHeight over the drop point --
    -- otherwise this feature is a permanent altitude increase wearing a table.
    local flat = poiById('lsia')
    local flatRec = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, flat, A.altitude, 0.0, 90.0), 0.0, A)
    local fz, ffrom = BR.AirdropFlightZ(flatRec, P, A)
    ok(near(fz, flat.z + A.planeHeight),
        'over LSIA the Cargobob flies exactly 250m up and no higher', fz)
    eq(ffrom, nil, 'with nothing authored under the route to raise it')

    -- ...AND CHILIAD RIDGE IS THE CASE THE OWNER REPORTED. Authored at 400, so
    -- a flat 250 puts it at 650 -- and the summit POI is 780, 391m away. This is
    -- the drop the first attempt was written for and never lifted.
    local ridge = poiById('chiliad_ridge')
    local summit = poiById('chiliad')
    ok(ridge and summit, 'the two Chiliad POIs are still in the map file')
    ok(ridge.z + A.planeHeight < summit.z,
        'and a flat 250 over the ridge really is INSIDE the summit -- this test '
        .. 'would pass by accident otherwise',
        ('%.0f vs %.0f'):format(ridge.z + A.planeHeight, summit.z))
    -- On the bearing that points at the summit, which is the drop that goes
    -- wrong; the bearing is the server's per-drop roll, so this asks about the
    -- worst one rather than the average one.
    local hdg = BR.GtaHeading(BR.Bearing(ridge.x, ridge.y, summit.x, summit.y))
    local ridgeRec = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, ridge, A.altitude, 0.0, hdg), 0.0, A)
    local rz, rfrom = BR.AirdropFlightZ(ridgeRec, P, A)
    eq(rfrom, 'chiliad', 'the summit is what raises a drop on the ridge')
    ok(near(rz, summit.z + A.planeTerrainClearance),
        'and it flies 60m over the rock rather than 130m inside it', rz)
    ok(rz > ridge.z + A.planeHeight,
        'which is higher than the flat 250 it would otherwise have held')

    -- AND IT IS A CONSTANT, WHICH IS THE OWNER'S ACTUAL INSTRUCTION. The old
    -- floor moved every frame by design; this one is not a function of `now` at
    -- all, and that is asserted rather than assumed.
    local z1 = BR.AirdropFlightZ(ridgeRec, P, A)
    local z2 = BR.AirdropFlightZ(ridgeRec, P, A)
    eq(z1, z2, 'asking twice gives the same height -- there is no clock in it')

    -- THE RELEASE GEOMETRY, WHICH THE CORRIDOR HAD TO EARN AND THIS GETS FREE.
    -- The aircraft holds rec.gz + planeHeight and the crate leaves at
    -- rec.gz + alt, so the gap is planeAltAbove by arithmetic -- on a Chiliad
    -- drop that has been lifted 190m as much as on a flat one.
    local crateAtRelease = BR.AirdropCrateZ(ridgeRec, ridgeRec.tRelease, nil)
    ok(near(crateAtRelease, (ridgeRec.gz or 0.0) + A.altitude),
        'the crate leaves from the authored height, lift or no lift')
end

describe('the crate: authored where it leaves, probed where it lands')
do
    -- ═══ TWO ANCHORS, WHICH IS WHAT THE 250m HEIGHT FORCED ═══
    --
    -- The aircraft flies off `rec.gz` -- the authored POI z, because that is the
    -- only height that cannot fail to answer at a kilometre. The crate has to
    -- land on the surface that is really there, which only a probe knows. Those
    -- are different numbers whenever config/map.lua's first pass was off, and
    -- BR.AirdropCrateZ is where they are reconciled: authored at the release
    -- end, probed at the landing end, straight line between.
    local poi = { id = 'hill', x = 0.0, y = 0.0, z = 100.0 }
    local rec = BR.ArmAirdropRecord(
        BR.BuildAirdropSite(1, poi, A.altitude, 0.0, 0.0), 0.0, A)

    -- The probe says the real ground is 30m above the authored number.
    local probed = 130.0
    ok(near(BR.AirdropCrateZ(rec, rec.tRelease, probed), 100.0 + A.altitude),
        'at the release it is exactly where the aircraft is, authored')
    ok(near(BR.AirdropCrateZ(rec, rec.tLand, probed), probed),
        'and at the landing it is exactly on the probed surface')
    -- ═══ THE LINE IS THE SAME LINE; WHAT MOVED IS HOW FAST IT TRAVELS ALONG IT
    --     (2026-08-28) ═══
    --
    -- This used to assert the midpoint of the clock was the midpoint of the two
    -- anchors, which was true only because the descent was linear. Both anchors
    -- and the straight line between them are untouched by the flare, so what can
    -- still be said -- and is the thing worth saying -- is that the crate is ON
    -- that line at the height the solver reports, and past the middle of it by
    -- the time half the seconds have gone.
    local half = (rec.tRelease + rec.tLand) / 2
    local hz   = BR.AirdropCrateZ(rec, half, probed)
    local frac = BR.AirdropHeightAt(rec, half) / A.altitude
    ok(near(hz, probed + (100.0 + A.altitude - probed) * frac, 1e-9),
        'halfway through, it is on the same straight line at the curve\'s height',
        ('%.4f'):format(hz))
    ok(hz < (100.0 + A.altitude + probed) / 2,
        ('and below where a linear fall would put it -- %.1f against %.1f')
            :format(hz, (100.0 + A.altitude + probed) / 2))

    -- A CLIENT WITH NO PROBE ANSWER YET FALLS TO THE AUTHORED HEIGHT, which is
    -- what every other reader of rec.gz does and what the blip is drawn at.
    ok(near(BR.AirdropCrateZ(rec, rec.tLand, nil), 100.0),
        'no probe answer means the authored ground, not zero')
    -- 0 IS A REAL HEIGHT AND NOT AN ABSENCE. In Lua 0 is truthy, and a
    -- `groundZ or rec.gz` written the obvious way would still be right -- but
    -- the type test is what makes a false from a caller read as "no answer"
    -- rather than as sea level.
    ok(near(BR.AirdropCrateZ(rec, rec.tLand, 0.0), 0.0),
        'a probed zero is honoured as zero')

    ok(near(BR.AirdropCrateZ(nil, 0.0, 50.0), 0.0), 'no record, no height')

    -- AND AN UNARMED DROP HAS NOT STARTED FALLING. BR.AirdropProgress answers 0
    -- for a record with no tLand, so the box sits at its release height rather
    -- than reading a missing number as fully descended.
    local sited = BR.BuildAirdropSite(2, poi, A.altitude, 0.0, 0.0)
    ok(near(BR.AirdropCrateZ(sited, 1e9, probed), 100.0 + A.altitude),
        'a sited drop is still aboard, however late the clock is')
end

describe('descent: expiry is not the same question as visibility')
do
    -- THE 2026-08-22 PLAYTEST BUG, as arithmetic. "Should the blip be up" is
    -- false at BOTH ends of the window; "is this drop over" is only ever true at
    -- the far one. The client used to tear a drop down on the first predicate,
    -- so a clock estimate a few tens of milliseconds behind the server's
    -- destroyed the whole airdrop on the frame it arrived.
    local poi = { id = 'x', x = 0.0, y = 0.0, z = 0.0 }
    local cfg = { blipAfterOpenMs = 60000, blipMaxMs = 240000 }
    local rec = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)

    ok(not BR.AirdropBlipVisible(rec, 900.0, cfg),
        'a record from the future is not visible yet...')
    ok(not BR.AirdropExpired(rec, 900.0, cfg),
        '...and is emphatically not over -- this is the pair that used to be '
        .. 'one question')

    ok(not BR.AirdropExpired(rec, 1000.0, cfg), 'not over at tStart')
    ok(not BR.AirdropExpired(rec, 31000.0, cfg), 'not over as it lands')
    ok(not BR.AirdropExpired(rec, 91000.0, cfg),
        'not over a minute after landing, which the OLD rule ended at')
    ok(not BR.AirdropExpired(rec, 241000.0, cfg),
        'not over at the four-minute ceiling')
    ok(BR.AirdropExpired(rec, 241001.0, cfg), 'over a millisecond later')
    ok(BR.AirdropExpired(nil, 0.0, cfg), 'and no record is nothing to draw')

    -- THE TWO PREDICATES SHARE ONE BOUNDARY AND CANNOT DRIFT APART. They are
    -- read on different frames by different code, and a drop drawn past the
    -- moment its record is destroyed is the same class of bug as the one this
    -- block is named after.
    local drift = true
    for _, r in ipairs({ rec, (function()
            local o = BR.BuildAirdropRecord(1, poi, 260.0, 1000.0, 31000.0, 0.0)
            o.tOpen = 41000.0
            return o
        end)() }) do
        local ends = BR.AirdropBlipEndsAt(r, cfg)
        if BR.AirdropBlipVisible(r, ends, cfg) == BR.AirdropExpired(r, ends, cfg)
           or BR.AirdropBlipVisible(r, ends + 1, cfg)
              == BR.AirdropExpired(r, ends + 1, cfg) then
            drift = false
        end
    end
    ok(drift, 'visible and expired flip at exactly the same millisecond, on '
        .. 'both branches of the rule')

    -- A YEAR EARLY IS STILL NOT OVER. There is no lower bound at all, which is
    -- the whole point: however far behind a client's clock estimate is, the
    -- answer is "wait", never "throw it away".
    ok(not BR.AirdropExpired(rec, -1e9, cfg),
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

--- WHERE THE MATCH'S PLAYERS ARE, for the 200m gate (owner, 2026-08-22: "the
--- drop should never happen until a player is within 200m of the drop
--- location"). Keyed by server id, exactly as the real roster is.
---
--- EMPTY BY DEFAULT, and that is the interesting default rather than a lazy
--- one: a match nobody is standing in is the case where the drop must NOT
--- happen, and it is the one every existing test in this file was written
--- against without knowing it.
local roster = {}
BR.Roster = {
    get = function(src) return roster[src] end,
}

--- Put a player `dist` metres from a point, so the gate can be opened or held
--- open at will.
--- @param src integer
--- @param x number
--- @param y number
--- @param dist number   metres east of (x, y)
--- @param state string|nil  defaults to ALIVE
local function standAt(src, x, y, dist, state)
    roster[src] = {
        pos = { x = x + dist, y = y, z = 0.0 },
        state = state or BR.PlayerState.ALIVE,
    }
end

--- Nobody anywhere near anything.
local function clearRoster()
    roster = {}
end

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

-- ═══ THE NET GAME EVENT SURFACE, WHICH IS NEW AND IS THE RISKIEST LINE IN
--     THE WHOLE FEATURE ═══
--
-- server/airdrop.lua now cancels `startProjectileEvent` for flare projectiles,
-- so that every client's locally-fired flares are not relayed to the other
-- forty-seven. Cancelling that event TOO BROADLY would stop grenades, stickies
-- and molotovs replicating -- thrown weapons would become invisible to
-- everyone but the thrower, which looks like a netcode fault rather than like
-- one line in this file. So the handler is driven here as code.
local srvHandlers = {}
function AddEventHandler(name, fn)
    srvHandlers[name] = srvHandlers[name] or {}
    srvHandlers[name][#srvHandlers[name] + 1] = fn
end

local srvCancelled = false
function CancelEvent() srvCancelled = true end

--- FiveM's GetHashKey answers a SIGNED 32-bit integer while the wire carries
--- the UNSIGNED one, which is exactly the mismatch BR.NormHash exists for --
--- and a filter that silently never matches looks identical to an event that
--- never fires. So the rig's hashes are NEGATIVE, and the events below are
--- fired with the unsigned form.
local HASHES = {
    weapon_flare    = -1233104067,
    weapon_flaregun = -1198879012,
    weapon_grenade  = -1813897027,
    weapon_stickybomb = -1633413354,
}
function GetHashKey(s) return HASHES[s] or 4242 end

--- What a client would actually put on the wire for that weapon.
local function wireHash(name)
    return GetHashKey(name) & 0xFFFFFFFF
end

--- Fire a server event; answer whether a handler cancelled it.
local function fireServer(name, ...)
    srvCancelled = false
    for _, fn in ipairs(srvHandlers[name] or {}) do fn(...) end
    return srvCancelled
end

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
    clearRoster()
    gameMs = gameMs + 10000000
end

local function tick() jobs['airdrop.tick']() end

--- Put a player on top of the drop that has just been sited, so the 200m gate
--- opens on the next tick.
---
--- MOST BLOCKS BELOW WANT THIS IMMEDIATELY AFTER THE SITING, because they are
--- about the descent, the payout or the landing and not about the gate -- and
--- before 2026-08-22 the descent started on its own. The blocks that ARE about
--- the gate call standAt directly.
--- @param m table
--- @return table|nil rec
local function somebodyTurnsUp(m)
    local w = m.airdrop and m.airdrop.waiting[1]
    if not w then return nil end
    standAt(m.id * 100 + 1, w.rec.x, w.rec.y, 0.0)
    return w.rec
end

--- ANNOUNCEMENT TO TOUCHDOWN, which is the plane's run-in PLUS the fall.
--- Every block below that wants "wind the clock forward until it lands" wants
--- this rather than descentMs -- the two were the same number until the plane
--- put a release between them.
---
--- AND THE FALL IS NOT `descentMs` EITHER, SINCE 2026-08-28. The crate flares
--- out over the last 25 feet, so it is in the air 2.2s longer than the
--- cruise-rate reference says; a harness still winding forward by descentMs
--- would tick one second short of every landing in this file and report it as a
--- drop that never arrived.
local FLIGHT = (A.planeLeadMs or 0) + BR.AirdropFallMs(A)

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

describe('server: `brairdrop now` overrides perMatch, and only it does')
do
    -- ═══ THE OWNER'S 2026-08-23 REQUEST, AND ITS OTHER HALF ═══
    --
    -- "`brairdrop now` should be allowed multiple times per match as it's a
    -- manual command and should override our match limit."
    --
    -- The cap it is overriding is `perMatch`, which is read in ONE place --
    -- BR.Airdrop.begin, filling `pending` -- and the tick sites out of `pending`
    -- and nowhere else. So this block has to prove two things at once: the verb
    -- ignores the cap, AND the cap still binds everything that is not the verb.
    reset()
    eq(A.perMatch, 1, 'the match limit is still one, and is not raised to fix '
                      .. 'this -- that would give every match more drops')

    local m = newMatch(1)
    BR.Airdrop.begin(m)
    eq(#m.airdrop.pending, 1, 'so the schedule holds exactly one drop')

    -- THE FIRST `now` SPENDS THE SCHEDULED ONE. Nothing new yet: this is the
    -- verb doing what it always did.
    commands['brairdrop'](0, { 'now' }, '')
    eq(#m.airdrop.pending, 0, 'the first `now` spends the scheduled drop')
    eq(#m.airdrop.waiting, 1, 'which is sited and waiting for a player')
    local first = m.airdrop.waiting[1].rec
    eq(first.n, 1, 'as drop 1')

    -- ═══ AND THE SECOND ONE IS THE WHOLE FEATURE ═══
    --
    -- This printed 'nothing pending' and did nothing at all before today: the
    -- queue was empty, and an empty queue was the cap.
    commands['brairdrop'](0, { 'now' }, '')
    eq(#m.airdrop.waiting, 2, 'a second `now` sites another drop anyway')
    local second = m.airdrop.waiting[2].rec
    ok(second.n ~= first.n,
        'on a number of its own, not the first one\'s',
        ('%s vs %s'):format(tostring(first.n), tostring(second.n)))

    -- ═══ A SECOND MANUAL DROP DOES NOT CORRUPT THE FIRST, WHICH IS STILL
    --     UN-ARMED ═══
    --
    -- THE DROP NUMBER IS WHY THIS IS AN ASSERTION AND NOT AN ASSUMPTION. The
    -- client's AIRDROP_SYNC handler treats a record carrying an `n` it already
    -- holds as a REPLACEMENT and tears the first drop down -- so a colliding
    -- number would mean the second /brairdrop now silently deleted the first
    -- drop's blip and crate. `sent + 1` collides exactly like that while a
    -- scheduled entry is still pending, which is why there is a nextDropNumber.
    ok(m.airdrop.waiting[1].rec == first,
        'the first drop is still the first entry, untouched')
    eq(#m.airdrop.live, 0, 'and neither is armed -- both are still waiting')
    ok(m.airdrop.waiting[1].items ~= m.airdrop.waiting[2].items,
        'each carries its own payout rather than sharing one')

    -- Both were announced to the match, as two records.
    local ns = {}
    for _, p in ipairs(published) do
        if p.event == BR.Net.AIRDROP_SYNC then ns[p.payload.n] = true end
    end
    ok(ns[first.n] and ns[second.n], 'and both records went out over the wire')

    -- ═══ THE GATE IS PER DROP, SO ARMING ONE LEAVES THE OTHER WAITING ═══
    --
    -- The one thing a second concurrent drop could plausibly break: a player
    -- walking to one of them must not dispatch the aircraft for both.
    standAt(m.id * 100 + 1, second.x, second.y, 0.0)
    tick()
    eq(#m.airdrop.live, 1, 'a player reaching one drop arms exactly one')
    eq(m.airdrop.live[1].rec.n, second.n, 'the one they walked to')
    eq(#m.airdrop.waiting, 1, 'and the other is still waiting for somebody')

    -- ...and it keeps working. "Multiple times" is not "twice".
    clearRoster()
    commands['brairdrop'](0, { 'now' }, '')
    commands['brairdrop'](0, { 'now' }, '')
    eq(#m.airdrop.waiting, 3, 'a third and fourth are no different from the second')

    -- ═══ AND NO TWO OF THEM ARE ON THE SAME POI ═══
    --
    -- Sited by an unmemoried uniform draw over the POI table, so two concurrent
    -- drops COULD land on one point until 2026-08-28 -- two crates and two blips
    -- on the same coordinates, and one player arming both, which is precisely
    -- what the per-drop gate a dozen lines up says cannot happen. It survived
    -- every seed this suite used and then stopped: trimming eight POIs out of
    -- the table for the surveyed map boundary moved this block's seed onto a
    -- collision, and both `now` drops came out on lsia_rw.
    --
    -- Asserted over the ids rather than over the distance, because "the same
    -- POI" is the thing that is wrong. Two different POIs 300m apart are two
    -- places; one POI twice is one place claimed twice.
    local sites, dupe = {}, nil
    for _, w in ipairs(m.airdrop.waiting) do
        if sites[w.rec.poi] then dupe = w.rec.poi end
        sites[w.rec.poi] = true
    end
    for _, l in ipairs(m.airdrop.live) do
        if sites[l.rec.poi] then dupe = l.rec.poi end
        sites[l.rec.poi] = true
    end
    ok(dupe == nil, 'and every concurrent drop is on a POI of its own',
        dupe and ('two drops on %s'):format(tostring(dupe)) or nil)

    -- ═══ AND NOW THE HALF THAT MUST NOT HAVE MOVED ═══
    --
    -- The AUTOMATIC path is `perMatch` entries in `pending` and a tick that
    -- sites out of `pending`. A fresh match must still get exactly one, however
    -- many times the console was used on the last one.
    local auto = newMatch(2)
    BR.Airdrop.begin(auto)
    eq(#auto.airdrop.pending, 1,
        'a new match still schedules exactly perMatch drops on its own')
    eq(auto.airdrop.sent or 0, 0, 'having announced none of them yet')
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

describe('server: siting a drop, and then arming it')
do
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()

    -- ═══ THE ANNOUNCEMENT COMES FIRST, AND NOTHING IS FLYING ═══
    --
    -- Owner, 2026-08-22: "the drop should never happen until a player is within
    -- 200m of the drop location." A gate on that is CIRCULAR unless the match
    -- has already been told where to go -- nobody would ever be within 200m
    -- except by accident. So the siting still announces, and only the descent
    -- waits.
    eq(#published, 1, 'one record goes out at schedule time')
    eq(published[1].event, BR.Net.AIRDROP_SYNC, 'on the airdrop channel')
    eq(#m.airdrop.waiting, 1, 'and the drop is waiting for somebody to turn up')
    eq(#m.airdrop.live, 0, 'with nothing whatsoever in the air')
    eq(#m.airdrop.pending, 0, 'and no longer pending')

    local sited = published[1].payload
    ok(sited.poi ~= nil, 'the record names the POI it is landing on')
    ok(sited.x ~= nil and sited.y ~= nil, 'and where that is, so a blip can go up')
    -- NO LANDING TIME. This is what tells every predicate that nothing has been
    -- released -- BR.AirdropArmed reads exactly this field.
    eq(sited.tLand, nil, 'but it carries NO landing time...')
    eq(sited.tRelease, nil, '...and no release time...')
    eq(sited.tArm, nil, '...and no arm time')
    ok(not BR.AirdropArmed(sited), 'so it is not armed')

    -- And everyone was told anyway, which is the entire point of the ordering.
    eq(#notices, 1, 'the match is told at the ANNOUNCEMENT, not at the arm')

    -- NOBODY IS ANYWHERE NEAR IT, so ticking changes nothing at all.
    for _ = 1, 5 do
        gameMs = gameMs + 1000
        tick()
    end
    eq(#m.airdrop.live, 0, 'ticking with an empty map arms nothing')
    eq(#published, 1, 'and re-announces nothing')

    -- ...and being CLOSE IS NOT CLOSE ENOUGH.
    standAt(101, sited.x, sited.y, (A.armWithin or 200.0) + 1.0)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 0, 'a player one metre outside the radius does not arm it')

    -- ═══ AND THEN SOMEBODY ARRIVES ═══
    standAt(101, sited.x, sited.y, A.armWithin or 200.0)
    gameMs = gameMs + 1000
    local armedAt = gameMs
    tick()
    eq(#m.airdrop.waiting, 0, 'standing exactly on the radius arms it')
    eq(#m.airdrop.live, 1, 'and the drop is in flight')
    eq(#published, 2, 'and the record is re-sent')

    local rec = published[2].payload
    ok(rec == sited, 'the SAME record, mutated and re-broadcast -- a re-send '
        .. 'replaces, so there is no new message')
    ok(BR.AirdropArmed(rec), 'and now it is armed')
    eq(rec.tArm, armedAt, 'stamped with the moment the wait ended')

    -- THREE TIMESTAMPS, AND THE MIDDLE ONE IS THE PLANE'S RUN-IN. Released at
    -- tArm + planeLeadMs, on the ground descentMs after that. A record that
    -- collapsed the first two would be a crate appearing in the sky the instant
    -- the gate opened, with a plane already leaving.
    ok(rec.tRelease - rec.tArm == A.planeLeadMs,
        'the plane gets planeLeadMs between the arm and the release',
        ('%s'):format(tostring(rec.tRelease - rec.tArm)))
    -- AND THE FALL IS BR.AirdropFallMs LONG, MEASURED FROM THE RELEASE. Not
    -- `descentMs`, which since 2026-08-28 is the CRUISE-RATE reference: the crate
    -- flares out over the last 25 feet, so the landing time is descentMs plus
    -- however long that tail takes. Nothing writes the total down and this is one
    -- of the three places it is checked.
    -- TO A MILLIONTH OF A MILLISECOND, and not exactly, because `tLand` is a
    -- sum built on a server timestamp in the hundreds of thousands and the fall
    -- is a fraction with a logarithm in it -- the last two bits of a double are
    -- not a property anybody wants pinned.
    ok(near(rec.tLand - rec.tRelease, BR.AirdropFallMs(A), 1e-6),
        'and the fall is BR.AirdropFallMs long, measured from the RELEASE',
        ('%s'):format(tostring(rec.tLand - rec.tRelease)))

    -- THE CONTENTS DO NOT TRAVEL, the same rule a chest's contents follow: a
    -- client that knew what was inside would only run for the good ones.
    ok(rec.items == nil, 'the published record carries no contents')
    ok(#m.airdrop.live[1].items >= A.minItems,
        'while the server is holding all of them')

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

describe('server: landing leaves a SEALED crate, not an open one')
do
    -- ═══ THE AUTO-OPEN IS GONE (owner, 2026-08-22: "Also we don't need to
    --     auto-open the crate. I changed my mind on that.") ═══
    --
    -- It was doing three things and only one of them was "opening": it retired
    -- the drop from the flight list, it left a husk, and it scattered the
    -- contents. The first still has to happen here; the other two are what a
    -- PLAYER open does, and BR.Loot has done exactly that for every crate on the
    -- map since long before airdrops existed. So what lands now is ONE ordinary
    -- container entry carrying the payout as its contents.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    -- Somebody is standing on it, so the 200m gate opens on the next tick and
    -- this block is about the LANDING rather than about the gate.
    local rec = somebodyTurnsUp(m)
    gameMs = gameMs + 1000
    tick()

    eq(#spawned, 0, 'nothing is on the ground while it is still falling')

    gameMs = gameMs + FLIGHT
    tick()

    eq(#m.airdrop.live, 0, 'the drop is no longer in flight')
    eq(#spawned, 1, 'exactly ONE thing lands: the sealed crate')

    local crate = spawned[1].stack
    eq(crate.kind, 'chest', 'and it is an ordinary container kind...')
    eq(crate.prop, A.crateProp, '...wearing the sealed crate prop')
    ok(near(spawned[1].x, rec.x, 0.001), 'at the landing point')
    ok(near(spawned[1].y, rec.y, 0.001), 'exactly')

    -- ITS OWN ITEM ID, which is not decoration: the client resolves a prop's
    -- SIZE from the item id, and an airdrop crate calling itself 'chest' like
    -- the other 1300 would be drawn at their size (owner: crate and husk 2x).
    eq(crate.item, 'airdrop', 'it has an item id of its own, for the scale')
    eq(crate.huskItem, 'airdrophusk', 'and names what it becomes when opened')
    eq(crate.huskProp, A.huskProp, 'wearing the airdrop husk prop')

    -- THE CONTENTS ARE INSIDE IT AND HAVE NOT TRAVELLED. This is the whole
    -- point of the change, and it is also what keeps the payout secret until
    -- somebody actually opens the box.
    ok(type(crate.contents) == 'table', 'the payout is INSIDE the crate')
    ok(#crate.contents >= A.minItems and #crate.contents <= A.maxItems,
        ('and it is %d-%d items'):format(A.minItems, A.maxItems),
        #(crate.contents or {}))

    -- THE VOLTS PILE AND THE EXCLUSIVES ARE IN THERE. They become ordinary
    -- registry entries when the crate is opened -- which is the whole reason
    -- they inherit the range check, the rate limit, the first-come arbitration
    -- and the not-yours-to-see refusal that docs/security.md describes.
    local piles, explosives = 0, 0
    local exclusive = {}
    for _, w in ipairs(BR.Config.AirdropWeapons) do exclusive[w.id] = true end
    for _, s in ipairs(crate.contents) do
        if s.kind == 'volts' then
            piles = piles + 1
            eq(s.count, A.voltsAmount, 'the pile is worth the configured amount')
            ok(type(s.prop) == 'string' and s.prop ~= '',
                'and carries its own prop -- no id table can resolve one for it')
        end
        if exclusive[s.item] then explosives = explosives + 1 end
    end
    eq(piles, 1, 'exactly one Volts pile is in the crate')
    eq(explosives, 2, 'and two of the weapons found nowhere else')

    -- THE RECORD OUTLIVES THE FLIGHT NOW, because the open has to find it to
    -- stamp tOpen on. It used to be dropped at landing.
    ok(m.airdrop.landed and m.airdrop.landed[rec.n] == rec,
        'the record is kept, keyed by drop number, for the open to find')

    -- ─── AND THE OPEN, WHICH IS WHAT STARTS THE BLIP'S LAST MINUTE ───
    eq(rec.tOpen, nil, 'an unopened crate has no open time')
    local before = #published
    BR.Airdrop.opened(m, rec.n)
    eq(rec.tOpen, gameMs, 'opening it stamps the moment onto the record')
    eq(#published, before + 1, 'and re-publishes the record')
    eq(published[#published].payload, rec, 'the same record, re-sent')
    eq(published[#published].event, BR.Net.AIRDROP_SYNC,
        'over AIRDROP_SYNC -- a re-send replaces, so there is no new message')

    -- ONCE. A second open cannot happen through the claim path (the crate is a
    -- husk by then and a husk is refused) but the guard is what stops a
    -- re-entrant call pushing the blip's expiry further out.
    local at = rec.tOpen
    gameMs = gameMs + 5000
    BR.Airdrop.opened(m, rec.n)
    eq(rec.tOpen, at, 'a second open does not move the blip\'s expiry')

    -- An unknown drop number is not an error.
    BR.Airdrop.opened(m, 99)
    BR.Airdrop.opened(nil, 1)

    -- AND NOTHING ELSE LANDS. Exactly one airdrop per match, no more --
    -- including after enough time has passed for another retry to be due,
    -- which is the case a same-tick loop would not reach.
    for _ = 1, 10 do
        gameMs = gameMs + (A.retryEveryMs or 5000)
        tick()
    end
    eq(#spawned, 1, 'nothing lands twice')
    eq(#m.airdrop.pending, 0, 'the schedule is spent')
end

describe('server: nobody comes, so the match gets no airdrop')
do
    -- ═══ THE OWNER'S DECISION, 2026-08-22 ═══
    --
    --   "Correct - if nobody goes to the area where the drop is ready to happen
    --    within the allotted time, then no drop should happen."
    --
    -- So the gate does not expire into an unwatched drop, and it does not retry
    -- somewhere else. The blip runs out and the match gets nothing.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    local rec = published[1].payload
    eq(#m.airdrop.waiting, 1, 'the drop is sited and waiting')

    -- Somebody is in the match, but on the far side of the map the whole time.
    standAt(101, rec.x, rec.y, 4000.0)

    -- ═══ "THE ALLOTTED TIME" IS THE BLIP'S OWN CEILING, AND THE TWO SHARE ONE
    --     CLOCK ═══
    --
    -- BR.AirdropExpired is the single question, so the instant the blip goes out
    -- is the instant the drop is abandoned. Two separate timers here would be
    -- two things that could disagree, and the disagreement would be a blip
    -- marking a crate that was never coming.
    gameMs = gameMs + A.blipMaxMs
    tick()
    eq(#m.airdrop.waiting, 1, 'still waiting at exactly the ceiling')

    gameMs = gameMs + 1
    tick()
    eq(#m.airdrop.waiting, 0, 'and abandoned a millisecond past it')
    eq(#m.airdrop.live, 0, 'nothing ever flew')
    eq(#spawned, 0, 'and nothing is on the ground')

    -- ═══ SPENT, NOT RETRIED ═══
    --
    -- The match was already TOLD an airdrop was coming; announcing a second one
    -- somewhere else would read as two airdrops in a match the owner asked to
    -- have exactly one. `sent` was counted at the announcement for this reason.
    eq(#m.airdrop.pending, 0, 'the schedule is spent, not returned to pending')
    eq(m.airdrop.sent, 1, 'and the drop counts as this match\'s one airdrop')

    for _ = 1, 20 do
        gameMs = gameMs + (A.retryEveryMs or 5000)
        tick()
    end
    eq(#published, 1, 'nothing is ever announced again')
    eq(#spawned, 0, 'and no crate arrives late')

    -- NOTHING IS SENT TO THE CLIENTS EITHER. Their blip expires off the same
    -- record and the same clock at the same instant, which is the whole reason
    -- this needs no message.
    eq(#published, 1, 'and no teardown message was needed')

    -- ═══ AND IT SAYS SO, WITH THE NUMBER THAT RETUNES THE THRESHOLD ═══
    --
    -- A match that showed a blip and produced nothing reads as a bug from a
    -- chair. The closest approach anybody actually made is both the proof it
    -- was working and the number that says whether 200m is right.
    ok(m.airdrop.outcome ~= nil, 'the match records WHY it got no airdrop')
    -- A REAL NUMBER, NOT math.huge. The closest approach is the whole value of
    -- this line -- it is how `armWithin` gets retuned from a playtest -- and an
    -- untracked one would still read as ">= 4000" against a lazy assertion
    -- while telling the owner nothing. A mutation pass proved exactly that.
    local closest = m.airdrop.outcome and m.airdrop.outcome.closest
    ok(closest ~= nil and closest < math.huge,
        'with a MEASURED closest approach rather than "nobody was ever seen"',
        tostring(closest))
    ok(closest and near(closest, 4000.0, 1.0),
        'and it is the distance that player actually kept', tostring(closest))

    logs = {}
    commands['brairdrop'](0, {}, '')
    local said = false
    for _, line in ipairs(logs) do
        if line:find('NO DROP', 1, true) then said = true end
    end
    ok(said, 'and brairdrop says it plainly rather than showing an empty schedule')
end

describe('server: the gate is a one-way latch')
do
    -- WHAT IF THE ONLY NEARBY PLAYER DIES BEFORE THE PLANE ARRIVES? Nothing.
    -- Once armed, the record carries a tRelease and a tLand and the descent is a
    -- pure function of the published record and the synced clock, exactly as it
    -- always was. There is no path back.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    local rec = somebodyTurnsUp(m)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 1, 'somebody turned up and it armed')
    local tLand = rec.tLand

    -- They die, and then everybody leaves.
    clearRoster()
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 1, 'an empty map does not un-arm it')
    eq(rec.tLand, tLand, 'and does not move the landing time')

    gameMs = gameMs + FLIGHT
    tick()
    eq(#spawned, 1, 'the crate arrives regardless -- it had already left')
end

describe('server: a DBNO player still counts, a lobby one does not')
do
    -- ALIVE OR DOWNED IS "IN THE MATCH". A downed player is about to be revived
    -- or finished off right next to the crate, which is exactly the fight this
    -- feature is for. Somebody watching from the lobby is not.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    local rec = published[1].payload

    standAt(101, rec.x, rec.y, 0.0, BR.PlayerState.LOBBY)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 0, 'a lobby player standing on it arms nothing')

    standAt(101, rec.x, rec.y, 0.0, BR.PlayerState.DBNO)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 1, 'a downed one does')
end

describe('server: a roster entry with no position is not at the origin')
do
    -- THE ROSTER SAMPLES AT 4Hz AND A PLAYER WHO HAS JUST CONNECTED HAS NO
    -- POSITION YET. Reading that as (0, 0) would put them in the ocean
    -- south-west of Los Santos -- a real place, with real POIs within 200m of
    -- it -- and open the gate for somebody who is nowhere.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    eq(#m.airdrop.waiting, 1, 'sited and waiting')

    -- In the match, alive, and the server has never had a position for them.
    roster[101] = { state = BR.PlayerState.ALIVE }
    for _ = 1, 3 do
        gameMs = gameMs + 1000
        tick()
    end
    eq(#m.airdrop.live, 0, 'a player with no sampled position arms nothing')
    eq(#m.airdrop.waiting, 1, 'and the drop is still waiting')
end

describe('server: the storm cap is re-checked while the drop waits')
do
    -- BOTH ARE RE-CHECKED NOW. This block's comment used to say the phase cap
    -- was re-asked and the margin was not, because the margin was believed to be
    -- self-correcting -- a point outside the circle is a point nobody is near.
    -- It is not, and the block below this one is why: the drop is ANNOUNCED at
    -- siting, so a blip stands over the point telling the match to run at it.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    local rec = published[1].payload
    eq(#m.airdrop.waiting, 1, 'sited while the storm was early enough')

    m.storm.phase = (A.maxPhase or 4) + 1
    standAt(101, rec.x, rec.y, 0.0)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 0, 'a player on the spot cannot arm it past the cap')
    eq(#m.airdrop.waiting, 0, 'the drop is abandoned instead')
    eq(#spawned, 0, 'and nothing lands')
    ok(m.airdrop.outcome ~= nil, 'and the match records why')
end

describe('server: the margin is re-checked when the wait ends')
do
    -- ═══ THE 2026-08-23 PLAYTEST BUG, AS CODE (owner: "aidrops aren't spawning
    --     within the circle at all times") ═══
    --
    -- The margin used to be solved once, at siting, against the SOONEST landing.
    -- Since the 200m gate a drop can sit for four minutes -- longer than a storm
    -- phase -- and the argument that this was safe was that a point outside the
    -- circle is a point nobody is near. It is exactly the point everybody is
    -- near: the blip has been standing over it since the announcement.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    tick()
    local rec = published[1].payload
    eq(#m.airdrop.waiting, 1, 'sited under the circle that was showing')

    -- The storm turns over a phase while somebody walks: a new circle, four
    -- kilometres from the place the match was told to go to.
    m.storm = BR.BuildStormRecord(3, rec.x + 4000.0, rec.y, 900.0,
        rec.x + 4000.0, rec.y, 900.0, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0)

    standAt(101, rec.x, rec.y, 0.0)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 0, 'a player standing on it cannot arm it any more')
    eq(#m.airdrop.waiting, 0, 'the drop is abandoned instead')
    eq(#spawned, 0, 'and no crate is ever put on the ground outside the circle')
    -- WHICH RULE REFUSED IT. There are three ways a waiting drop ends without
    -- landing and /brairdrop printing "nobody came" for all three is how a
    -- playtest goes after the wrong bug.
    ok(m.airdrop.outcome
       and tostring(m.airdrop.outcome.why):find('circle moved off it', 1, true),
        'and the outcome names the circle rather than blaming the players',
        m.airdrop.outcome and m.airdrop.outcome.why)
end

describe('server: siting solves the whole gate window, not the first landing')
do
    reset()
    local m = newMatch(1)
    local poi = BR.Config.Map.GetPOI('lsia')
    -- Phase 2 mid-sweep: a 2600m circle closing onto a 950m one a kilometre
    -- away, over ten minutes -- longer than the four the gate allows a drop to
    -- wait, so the window really does straddle a moving circle.
    m.storm = BR.BuildStormRecord(2, poi.x - 1000.0, poi.y, 2600.0,
        poi.x, poi.y, 950.0, gameMs, 0, 600000, 1.0)
    BR.Airdrop.begin(m)
    m.airdrop.pending[1].dueAt = gameMs
    local sitedAt = gameMs
    tick()
    local rec = published[1] and published[1].payload
    ok(rec ~= nil, 'a POI still qualifies')

    if rec then
        -- THE POINT CLEARS THE DEADLINE, not merely the soonest landing.
        local late = sitedAt + A.blipMaxMs + FLIGHT
        local cx, cy, r = BR.StormAt(m.storm, late)
        ok(BR.Dist(rec.x, rec.y, cx, cy) <= r - A.insideBy,
            'it is still 250m inside the circle at the LATEST landing the gate allows')
        -- ...AND THE NEXT CIRCLE, which is the owner's own half of the proposal.
        ok(BR.Dist(rec.x, rec.y, m.storm.cx1, m.storm.cy1)
           <= m.storm.r1 - A.insideBy,
            'and 250m inside the circle the storm is shrinking toward')
    end

    -- AND THE RULE REALLY IS STRICTER. The single circle the old code asked
    -- about accepts points this one refuses; if that ever stops being true the
    -- window has quietly become decoration.
    local sx, sy, sr = BR.StormAt(m.storm, sitedAt + FLIGHT)
    local before = BR.AirdropSites(BR.Config.Map.POIs, sx, sy, sr,
        A.insideBy, BR.LootPlaceable)
    local after = BR.AirdropSitesIn(BR.Config.Map.POIs,
        BR.AirdropLandingCircles(m.storm, sitedAt, A, A.blipMaxMs),
        A.insideBy, BR.LootPlaceable)
    ok(#after < #before,
        'the window refuses candidates the single circle accepted',
        ('%d vs %d'):format(#after, #before))
    ok(#after > 0, 'without refusing all of them')
end

describe('server: a forced drop keeps its exemption at the arm')
do
    -- `/brairdrop <poiId>` exists to put a drop somewhere specific without
    -- waiting for the circle to cooperate. Re-imposing the margin at the arm
    -- would make it work only where the circle already agreed, which is the
    -- case that never needed the verb.
    reset()
    local m = newMatch(1)
    BR.Airdrop.begin(m)
    commands['brairdrop'](0, { 'sandy' }, '')
    local rec = published[1].payload
    m.storm = BR.BuildStormRecord(2, rec.x + 5000.0, rec.y, 900.0,
        rec.x + 5000.0, rec.y, 900.0, gameMs, 24 * 60 * 60 * 1000, 1000, 1.0)
    standAt(101, rec.x, rec.y, 0.0)
    gameMs = gameMs + 1000
    tick()
    eq(#m.airdrop.live, 1,
        'a forced drop arms with a player on it, wherever the circle has gone')
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
    eq(#notices, 1, 'and the match is told, in the same words')

    -- FORCING THE POI BYPASSES THE CIRCLE, NOT THE OWNER'S RULE. The dev verb
    -- exists so a drop can be put somewhere specific without waiting for the
    -- storm to cooperate; it is not a way to make one happen with nobody
    -- watching, because that is the thing the 200m gate was added to prevent.
    eq(#m.airdrop.waiting, 1, 'and it is SITED, waiting for somebody to turn up')
    eq(#m.airdrop.live, 0, 'not in flight')

    -- ...and `brairdrop arm` is the second half, because walking a character to
    -- within 200m of wherever the circle put a POI is minutes per attempt.
    commands['brairdrop'](0, { 'arm' }, '')
    eq(#m.airdrop.live, 1, 'which the arm verb starts by hand')
    eq(#published, 2, 're-announcing the same record')

    gameMs = gameMs + FLIGHT
    tick()
    eq(#spawned, 1, 'and it lands sealed on arrival like any other')
    eq(spawned[1].stack.kind, 'chest', 'as a container')

    -- Arming when there is nothing waiting is not an error.
    commands['brairdrop'](0, { 'arm' }, '')

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

describe('server: flare projectiles do not replicate, and nothing else changes')
do
    -- ═══ THE MOST DANGEROUS LINE IN THE FEATURE, DRIVEN AS CODE ═══
    --
    -- The flares are real projectiles now, and a projectile REPLICATES: FiveM's
    -- server carries a full wire parser for CStartProjectileEvent and relays it
    -- to every client that can see the shooter. Without this handler each
    -- client would draw its own pair plus forty-seven remote copies.
    --
    -- Cancelling suppresses the relay -- both of the server's packet paths gate
    -- it on `if (eventHandler()) { RouteEvent(...); }` -- but cancelling too
    -- MUCH is catastrophic in a way that would not look like this file:
    -- grenades, stickies and molotovs are projectiles the match requires to
    -- replicate, and suppressing those makes thrown weapons invisible to
    -- everyone but the thrower.
    local before = BR.Airdrop.flaresSuppressed

    ok(fireServer('startProjectileEvent', 1,
        { weaponHash = wireHash('weapon_flare') }),
        'a flare projectile is refused')
    ok(fireServer('startProjectileEvent', 1,
        { weaponHash = wireHash('weapon_flaregun') }),
        'and so is the flare gun, because /brflare weapon can switch to it')

    -- ═══ AND THE THINGS PLAYERS ACTUALLY THROW ARE UNTOUCHED ═══
    ok(not fireServer('startProjectileEvent', 1,
        { weaponHash = wireHash('weapon_grenade') }),
        'a GRENADE still replicates -- suppressing it would make thrown '
        .. 'weapons invisible to everyone but the thrower')
    ok(not fireServer('startProjectileEvent', 1,
        { weaponHash = wireHash('weapon_stickybomb') }),
        'and so does a sticky')

    eq(BR.Airdrop.flaresSuppressed - before, 2,
        'the counter follows the cancels exactly, so a filter that matches '
        .. 'everything and one that matches nothing can be told apart')

    -- ═══ THE SIGNED/UNSIGNED TRAP, WHICH IS INVISIBLE WHEN IT FIRES ═══
    --
    -- GetHashKey answers a NEGATIVE 32-bit integer in Lua; the wire carries the
    -- unsigned one. Comparing them directly is false for the same weapon, the
    -- filter never matches, and the symptom is "flares replicate anyway" --
    -- which looks exactly like the event not being raised at all. Both forms
    -- must be accepted.
    ok(fireServer('startProjectileEvent', 1,
        { weaponHash = GetHashKey('weapon_flare') }),
        'the SIGNED form of the same hash is refused too, so a build that '
        .. 'reports it either way is handled')

    -- Malformed payloads must not throw on a handler the whole server's
    -- projectile traffic runs through.
    ok(not fireServer('startProjectileEvent', 1, nil), 'nil data cancels nothing')
    ok(not fireServer('startProjectileEvent', 1, 'nope'),
        'and neither does a payload that is not a table')
    ok(not fireServer('startProjectileEvent', 1, {}),
        'and neither does one with no weaponHash at all')
    ok(not fireServer('startProjectileEvent', 1, { weaponHash = 'banana' }),
        'and neither does a weaponHash that is not a number')
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

--- WHERE THIS CLIENT'S PED IS. Drives the plane's view-radius gate: the owner
--- asked for no plane when nobody is near enough to see it (2026-08-22), and
--- "near enough" is a distance from THIS ped to the drop point.
local me = { x = 100.0, y = 200.0, z = 12.0, h = 0.0 }

--- WHICH FLARE MODELS THIS "BUILD" HAS. The 2026-08-21 flares named
--- `prop_flare_01a`, which is not a model in GTA V -- IsModelValid refused it,
--- loadModel returned false, and the entire flare branch (props AND particles,
--- both behind one `if`) never ran. So the rig models the thing that actually
--- broke: a name can be INVALID, and the code has to notice.
local validModels = nil   -- nil = everything is valid, a table = only these

function GetHashKey(s) return s end
function IsModelValid(m)
    if not validModels then return 1 end
    return validModels[m] and 1 or 0
end
function PlayerPedId() return 1 end
--- WHERE AN ENTITY IS, and it has to be per-entity rather than always the
--- player: the crate, the canopy, the aircraft and the object route's flare
--- props are all separate handles at separate places, and a rig that answered
--- the player's position for every one of them would put every part of a drop
--- wherever the player happened to be standing and still pass every distance
--- check.
function GetEntityCoords(e)
    local t = ents[e] or vehicles[e] or peds[e]
    if t then return t end
    return me
end
function GetEntityHeading(e)
    local t = ents[e] or vehicles[e] or peds[e]
    if t and t.heading then return t.heading end
    return me.h
end
--- EVERY MODEL REQUEST, IN ORDER, so a test can ask WHEN a stream was asked
--- for and not merely whether the prop exists. That is the whole of the
--- 2026-08-23 perf change: nothing on the render path may wait for an asset, so
--- the requests have to land at the announcement and not on the release frame.
local modelRequests = {}
function RequestModel(m) modelRequests[#modelRequests + 1] = m end
function HasModelLoaded(m)
    if validModels and not validModels[m] then return 0 end
    return modelLoaded
end
function SetModelAsNoLongerNeeded() end
function RequestAnimDict() end
function HasAnimDictLoaded() return 1 end
function PlayEntityAnim(e, anim, dict) anims[#anims + 1] = { e = e, anim = anim, dict = dict } end
function GetCurrentResourceName() return 'br_core' end

function RequestNamedPtfxAsset() end
function HasNamedPtfxAssetLoaded() return ptfxLoaded end
function UseParticleFxAsset(a) fxAssetUsed[#fxAssetUsed + 1] = a end
--- WHICH NUMBER A FAILED START ANSWERS WITH. It is -1 per Cfx's own looped
--- wrapper and 0 per its non-looped one -- the engine's own bindings disagree,
--- so the rig drives BOTH. Both are truthy in Lua, which is the half that
--- shipped.
local ptfxFailValue = -1
function StartParticleFxLoopedOnEntity(name, ent, ox, oy, oz, _, _, _, scale)
    if ptfxHandle == 0 then
        fxStarted[#fxStarted + 1] =
            { name = name, ent = ent, handle = ptfxFailValue }
        return ptfxFailValue
    end
    ptfxHandle = ptfxHandle + 1
    fxStarted[#fxStarted + 1] = { name = name, ent = ent, handle = ptfxHandle,
                                  ox = ox, oy = oy, oz = oz, scale = scale }
    return ptfxHandle
end
function StopParticleFxLooped(h) fxStopped[#fxStopped + 1] = h end
--- The liveness check Cfx's own wrapper uses. Driven by `fxAlive` below so a
--- handle that came back non-(-1) but DEAD can be tested -- which is one of the
--- two ways a particle start fails and neither was checked before.
local fxAlive = true
function DoesParticleFxLoopedExist() return fxAlive and 1 or 0 end

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
--- THE GROUND, AND IT HAS TO BE ABLE TO VARY WITH POSITION.
---
--- One flat number was enough while the only thing probed was the drop point.
--- The aircraft's terrain floor probes a CORRIDOR (owner, 2026-08-23: "make sure
--- the cargobob avoids terrain, because drops at chili[ad]") and a rig that
--- answered the same height everywhere would agree with a mountain and with a
--- salt flat alike. `ground.at` is opt-in so every test written before this one
--- keeps the flat answer it was written against.
function GetGroundZFor_3dCoord(x, y)
    if ground.at then return ground.ok, ground.at(x, y) end
    return ground.ok, ground.z
end

--- [entity] = the LOD distance it was asked to draw from.
---
--- There is no getter for this in the engine either, so what the rig can assert
--- is exactly what /brairdrop can print: the call was made, on that handle, with
--- that number. That is the whole of the fix for "the loose flares drop before
--- the cargo" -- see drawFar in br_core/client/airdrop.lua.
local lods = {}
function SetEntityLodDist(e, d) lods[e] = d end

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
--- WHICH SURFACE THIS BLIP IS DRAWN ON. A drop puts up two blips at the same
--- coordinate -- one restricted to the big map, one to the minimap -- because
--- SetBlipScale is per BLIP and not per surface, and the owner wants two
--- different sizes (2026-08-23). Recorded rather than nooped: which display id
--- landed on which blip IS the feature.
function SetBlipDisplay(b, d) if blips[b] then blips[b].display = d end end

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

--- [entity] = the last scale it was drawn at. There is no SetEntityScale in
--- GTA V (#166) so the real BR.Native.propScale drives the transform matrix;
--- what matters here is only that every part gets asked for the RIGHT size and
--- keeps being asked after every matrix write.
local scaled = {}

--- What BR.Native.pedReachable answers, and why. The rooftop check.
local reachable, reachWhy = true, 'ok'

BR.Native = {
    blipName = function(b, n) if blips[b] then blips[b].name = n end end,
    propScale = function(obj, k)
        if not obj or not k or k == 1.0 then return end
        scaled[obj] = k
    end,
    pedReachable = function() return reachable, reachWhy end,
}

-- ═══ THE PROJECTILE SURFACE, WHICH IS THE THIRD ATTEMPT'S WHOLE BET ═══
--
-- A fired flare has NO HANDLE. There is no native that reports one, so nothing
-- in the game and nothing in this rig can ask whether it rendered. What CAN be
-- asserted is that the call was made, with the right weapon, at the right
-- place, at the right cadence -- which is exactly the set of things the first
-- two attempts got wrong and nobody could see.
local shots = {}        -- every ShootSingleBulletBetweenCoords
local weaponAssets = {} -- [hash] = true once requested
local weaponLoads = 1   -- what HasWeaponAssetLoaded answers

function RequestWeaponAsset(h) weaponAssets[h] = true end
function HasWeaponAssetLoaded(h)
    if weaponLoads == 0 then return 0 end
    return weaponAssets[h] and 1 or 0
end
function ShootSingleBulletBetweenCoords(x1, y1, z1, x2, y2, z2, damage, p7,
                                        weapon, owner, audible, invisible, speed)
    shots[#shots + 1] = {
        x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2,
        damage = damage, p7 = p7, weapon = weapon, owner = owner,
        audible = audible, invisible = invisible, speed = speed,
    }
end

--- What SET_AUDIO_VEHICLE_PRIORITY was asked for. The native returns void and
--- has no getter, so this table IS the whole of what can be validated -- which
--- is the honest answer to the owner's "we need a way to validate it".
local audioCalls = {}
function SetAudioVehiclePriority(veh, pri)
    audioCalls[#audioCalls + 1] = { veh = veh, pri = pri }
end

--- ═══ A BAITED ACCESSOR, KEPT ON PURPOSE AFTER ITS CALLER WAS DELETED ═══
---
--- BR.Loot.airdropBox() was the landed box's whereabouts, and client/flares.lua
--- asked it ten times a second so it could stand a pair of flares there. The
--- owner asked for that back out on 2026-08-23 and the real accessor is gone
--- from br_core/client/loot.lua with it.
---
--- THE STUB STAYS, AND IT COUNTS. "No flares appear on the husk" can be
--- satisfied by a landed pass that runs and quietly fails -- a model that will
--- not load, a route that returns early. Counting the calls asserts the
--- stronger and simpler thing: NOBODY IS ASKING WHERE THE BOX IS. It is also
--- what fails loudly if the accessor is ever reintroduced upstream.
local lootBox, boxAsked = nil, 0
BR.Loot = { airdropBox = function() boxAsked = boxAsked + 1 return lootBox end }

loadAll({ 'br_core/client/flares.lua', 'br_core/client/airdrop.lua' })

local render = loops['airdrop.render']

local function clientReset()
    -- onResourceStop is also what drops the cached flare model and weapon
    -- asset, so every reset re-resolves them against whatever this test says.
    fire('onResourceStop', 'br_core')
    ents, blips, attaches, anims, moves = {}, {}, {}, {}, {}
    vehicles, peds = {}, {}
    fxStarted, fxStopped, fxAssetUsed = {}, {}, {}
    shots, weaponAssets, audioCalls = {}, {}, {}
    modelRequests = {}
    weaponLoads = 1
    scaled = {}
    lods = {}
    ground.ok, ground.z, ground.at = 1, 12.0, nil
    -- ═══ THE AUTHORED TABLE THE FLIGHT HEIGHT IS SOLVED FROM (2026-08-23) ═══
    --
    -- EMPTY BY DEFAULT, because every client test but the terrain one is asking
    -- what the aircraft does with nothing under it, and the rig's drop point
    -- (100, 200) sits close enough to `casino` on the real map that a change of
    -- heading could start lifting it. The terrain block installs its own summit
    -- and the pure half above still measures against the real 128 POIs, which is
    -- where that coverage belongs.
    --
    -- SAFE TO OVERWRITE AND NEVER RESTORE: every remaining test in this file is
    -- a client test, and the siting half that reads the real table has run.
    BR.Config.Map.POIs = {}
    modelLoaded, ptfxLoaded = 1, 1
    ptfxHandle = 900
    fxAlive = true
    validModels = nil
    reachable, reachWhy = true, 'ok'
    lootBox = nil
    -- THE ROUTE IS RESET TOO. /brflare edits the live config on purpose, and a
    -- test that switched to the object route would otherwise poison every test
    -- after it -- which is the same silent-carry-over class of bug the flares
    -- themselves have twice been.
    A.flareRoute = 'projectile'
    A.flarePtfx  = true
    -- Standing ON the drop point, so the plane's view radius passes unless a
    -- test deliberately walks away.
    me.x, me.y, me.z = 100.0, 200.0, 12.0
    BR.State.me.state = BR.PlayerState.ALIVE
    gameMs = gameMs + 1000000
end

--- The model the object route will build, when a test switches to it.
local function flareProp()
    return A.flareModel
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

--- Announce a drop that has been SITED but NOT ARMED -- the state every drop
--- now starts in, while the server holds it waiting for somebody to come within
--- `armWithin` (owner, 2026-08-22).
---
--- Its record has a tStart and no tRelease, no tLand and no tArm. A blip and
--- nothing else.
--- `A.altitude` AND NOT A LITERAL, unlike announce() above. Since 2026-08-23 the
--- aircraft's height and the crate's release height are two halves of one number
--- -- `altitude + planeAltAbove == planeHeight` -- so a sited drop built with a
--- stale 260 would put the box above the Cargobob that is meant to be carrying
--- it, and every geometry assertion in the terrain block would be measuring the
--- rig's own inconsistency.
local function announceSited()
    local rec = BR.BuildAirdropSite(1,
        { id = 'lsia', x = 100.0, y = 200.0, z = 30.0 }, A.altitude, gameMs, 90.0)
    fire(BR.Net.AIRDROP_SYNC, rec)
    return rec
end

--- ...and then the server arms it and re-sends the SAME record.
local function armSited(rec)
    BR.ArmAirdropRecord(rec, gameMs, A)
    fire(BR.Net.AIRDROP_SYNC, rec)
    return rec
end

local function oneBlip()
    for _, b in pairs(blips) do return b end
    return nil
end

--- How many blips exist at all.
local function blipCount()
    local n = 0
    for _ in pairs(blips) do n = n + 1 end
    return n
end

--- A drop puts up TWO blips at the same coordinate, restricted to one map
--- surface each, because SetBlipScale is per blip and not per surface and the
--- owner wants two different sizes (2026-08-23). These pick them apart by the
--- only thing that distinguishes them.
--- @param display number
--- @return table|nil
local function blipOn(display)
    for _, b in pairs(blips) do
        if b.display == display then return b end
    end
    return nil
end

local function mapBlip()  return blipOn(A.blipDisplay) end
local function miniBlip() return blipOn(A.blipMinimapDisplay) end

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

describe('client: the blip, which is two blips')
do
    -- ═══ ONE DROP, TWO MARKERS, ONE PER MAP SURFACE (owner, 2026-08-23) ═══
    --
    -- "specifically the blip on the MINIMAP should show much smaller... The big
    -- map blip is perfect size"
    --
    -- THERE IS NO PER-SURFACE SCALE, which is the entire reason this is two
    -- objects. SetBlipScale sets ONE size that both the pause map and the
    -- minimap draw at, so no single blip can be 2.4 on one and small on the
    -- other. What is per-surface is DISPLAY (SET_BLIP_DISPLAY), so the drop puts
    -- up two blips at the same coordinate and restricts each to one surface.
    clientReset()
    announce()

    eq(blipCount(), 2, 'a drop puts up two blips, not one')

    ok(mapBlip()  ~= nil, 'one restricted to the big map')
    ok(miniBlip() ~= nil, 'and one restricted to the minimap')
    -- EMPTY RATHER THAN nil FROM HERE DOWN. If the split regresses to one blip
    -- the two lines above are the diagnosis, and the twenty below should report
    -- what else broke rather than indexing nil and taking the whole suite with
    -- them.
    local big  = mapBlip()  or {}
    local mini = miniBlip() or {}

    -- ═══ THE ENUM, PINNED AS LITERALS ═══
    --
    -- These are the two numbers the whole feature rests on and the ONE part of
    -- it that cannot be checked from inside Lua -- SET_BLIP_DISPLAY returns
    -- void and nothing reads a blip's display back. They are pinned as literals
    -- rather than against the config so that a config edit which breaks the
    -- split fails here, and they are checked against citizenfx/natives
    -- HUD/SetBlipDisplay.md: 3 and 4 are main map only, 5 and 9 are minimap
    -- only, 2/6 are both-selectable and 8/10 are both-not-selectable. The
    -- blog-level sources disagree with that table and with each other -- one
    -- widely-copied post calls 8 "minimap only", which it is not -- so the value
    -- and its provenance are written down together.
    eq(A.blipDisplay, 3,
        'the big map blip is display 3, which is main-map-only in the Cfx table')
    eq(A.blipMinimapDisplay, 5,
        'and the minimap one is 5, which is minimap-only -- and both are values '
        .. 'Rockstar\'s own scripts use, unlike 4 and 9')
    ok(A.blipDisplay ~= A.blipMinimapDisplay,
        'and they differ, or both blips land on the same surface at two sizes')

    -- ═══ THE SIZES, WHICH ARE THE POINT OF THE SPLIT ═══
    eq(big.scale, A.blipScale,
        'the big map keeps the size the owner called perfect')
    eq(A.blipScale, 2.4, 'which is still the 2x they asked for on 2026-08-22')
    eq(mini.scale, A.blipMinimapScale, 'and the minimap gets its own')
    ok(A.blipMinimapScale < A.blipScale,
        'which is smaller -- the whole request',
        ('%.2f vs %.2f'):format(A.blipMinimapScale, A.blipScale))
    -- "MUCH smaller", not a nudge. A 10% trim would satisfy the line above and
    -- would not be what was asked for.
    ok(A.blipMinimapScale <= A.blipScale * 0.5,
        'and MUCH smaller -- at most half, rather than a nudge')

    -- ═══ AND EVERYTHING ELSE IS IDENTICAL ON BOTH ═══
    --
    -- They are two renderings of one drop. A sprite or colour that drifted
    -- between them would read as two different things on two different maps.
    for _, b in ipairs({ big, mini }) do
        eq(b.sprite, A.blipSprite, 'with the sprite the owner asked for')
        eq(b.colour, A.blipColour, 'and the configured colour')
        ok(b.shortRange == false,
            'and it is NOT short range -- everyone in the match must see it, '
            .. 'and on the minimap that is what pins it to the edge')
        eq(b.name, A.blipName, 'and it is named, so the legend is not a heist')
        ok(b.x ~= nil and near(b.x, 100.0) and near(b.y, 200.0),
            'and both stand at the drop point')
    end

    -- A re-send replaces rather than stacking another pair on the same drop.
    announce()
    eq(blipCount(), 2, 'a re-sent record replaces rather than duplicating')
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

    -- OUTBOUND, and still flying while the box comes down behind it.
    --
    -- ═══ THE TRAIL ENDS TWO SECONDS BEFORE THE FALL NOW (2026-08-28) ═══
    --
    -- `descentMs` was halved to 15000 on the owner's "make the loot drop 2x the
    -- speed" and `planeTrailMs` is 15000, so for five days the aircraft left on
    -- exactly the instant the crate touched down. The flare added 2.2s to the
    -- FALL and nothing to the trail, so it now goes while the box is still in the
    -- air -- 8.5m up, doing about 4.9 m/s.
    --
    -- LEFT ALONE ON PURPOSE, and asserted rather than corrected. Deriving the
    -- trail from the descent curve would make a number the owner set move
    -- whenever an unrelated one does, and by then the Cargobob is 675m away and
    -- 250m up: nothing here ever depended on the order. What matters is that the
    -- relationship is written down, so the next change to either number is a
    -- change somebody has to look at rather than one they find in a playtest.
    eq(A.planeTrailMs, A.descentMs,
        'the trail window is still the cruise-rate reference exactly')
    do
        local shaped = BR.ArmAirdropRecord(
            BR.BuildAirdropSite(1, { id = 'x', x = 0.0, y = 0.0, z = 0.0 },
                                A.altitude, 0.0, 0.0), 0.0, A)
        local goes = shaped.tRelease + A.planeTrailMs
        ok(goes < shaped.tLand,
            ('the aircraft leaves %.2fs before the crate lands')
                :format((shaped.tLand - goes) / 1000.0))
        local left = BR.AirdropHeightAt(shaped, goes, A)
        ok(left > 0.0 and left < 15.0,
            ('with the box %.1fm up and already in its flare'):format(left))
    end

    gameMs = gameMs + A.planeTrailMs - 1
    render()
    ok(onePlane() ~= nil, 'still there at the end of the trail window')
    ok(onePlane().y > rec.y, 'north of the drop point now, outbound')
    ok(oneEnt() ~= nil, 'while the crate is still falling')

    gameMs = gameMs + 2
    render()
    eq(onePlane(), nil, 'and gone a millisecond later')
    eq(onePed(), nil, 'pilot and all')
    eq(oneEnt(), nil, 'on the same frame the crate finishes its fall')

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

    eq(blipCount(), 2, 'there are two blips')
    for h in pairs(blips) do RemoveBlip(h) end
    eq(oneBlip(), nil, 'something took them away')

    render()
    eq(blipCount(), 2, 'and the next frame puts both back')

    -- ═══ AND EACH SURFACE COMES BACK ON ITS OWN ═══
    --
    -- The two blips have separate handles, so a sweep can take one and leave
    -- the other. Sharing one existence check would mean whichever half survived
    -- kept the other half missing for as long as it lived -- the exact failure
    -- this re-assertion exists to prevent, reintroduced by the fix for it.
    local mini = miniBlip()
    for h, b in pairs(blips) do if b == mini then RemoveBlip(h) end end
    eq(miniBlip(), nil, 'the minimap half alone is taken')
    ok(mapBlip() ~= nil, 'while the big map half survives')
    render()
    ok(miniBlip() ~= nil, 'and the minimap half comes back on its own')
    eq(blipCount(), 2, 'without a second big-map blip appearing beside it')

    -- ONCE, THOUGH. Re-asserting has to be idempotent or a frame loop makes a
    -- blip per frame and the pause map fills with sixty copies a second.
    render(); render(); render()
    eq(blipCount(), 2, 'and exactly two, however many frames pass')

    -- BUT NOT AFTER THE WINDOW CLOSES. A blip that reappeared forever would be
    -- worse than one that vanished early.
    -- Past the four-minute ceiling, measured from the announcement -- nobody
    -- opened this one, which since the auto-open was removed is the ordinary
    -- case rather than the exotic one.
    gameMs = gameMs + A.blipMaxMs + 1
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
    -- ═══ BOTH BLIPS, SEPARATELY, BECAUSE "THE BLIP IS MISSING" IS NOW TWO
    --     DIFFERENT REPORTS ═══
    --
    -- Which surface the owner was looking at decides which half is broken, and
    -- a diagnostic that printed one handle would answer the wrong question half
    -- the time.
    ok(joined:find('big-map blip', 1, true) ~= nil,
        'and whether the big map blip actually exists')
    ok(joined:find('minimap blip', 1, true) ~= nil,
        'and the minimap one, which is a separate blip with its own handle')
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

    -- ═══ tLand IS OPTIONAL NOW, WHICH IS NOT THE SAME AS UNCHECKED ═══
    --
    -- A sited drop legitimately carries no landing time, so the handler cannot
    -- simply demand a number. Relaxing that into "anything goes" would let a
    -- non-number through into arithmetic on the render loop's hot path, which is
    -- how a bad record takes the whole airdrop down instead of being dropped.
    fire(BR.Net.AIRDROP_SYNC,
        { x = 1.0, y = 2.0, tStart = 0, tLand = 'banana' })
    eq(oneBlip(), nil, 'a tLand that is not a number is still refused')

    fire(BR.Net.AIRDROP_SYNC, { x = 1.0, y = 2.0, tStart = 0, tLand = {} })
    eq(oneBlip(), nil, 'and so is one that is a table')

    -- ...and the legitimate shape IS accepted, which is the other half.
    fire(BR.Net.AIRDROP_SYNC, { n = 1, x = 1.0, y = 2.0, tStart = gameMs })
    ok(oneBlip() ~= nil, 'while a sited record with no tLand at all gets a blip')
end

describe('client: every part is local and non-networked')
do
    clientReset()
    announce()
    render()

    local e = oneEnt()
    ok(e ~= nil, 'the crate is built')
    eq(e.model, A.crateProp, 'and it is the crate prop we already use')

    -- TWO OBJECTS, AND BOTH NON-NETWORKED. This is not a style check:
    -- `sv_entityLockdown relaxed` refuses a client-created NETWORKED entity
    -- outright, so a single `true` here is an object that silently never
    -- appears for anyone.
    --
    -- IT WAS FOUR UNTIL 2026-08-22. The flare props are gone -- the flares are
    -- fired projectiles now, which are the engine's and not entities of ours at
    -- all. If this ever counts more than two again, something has started
    -- creating flare objects on the default route.
    eq(entCount(), 2, 'a crate and a canopy, and nothing else')
    local networked = 0
    for _, x in pairs(ents) do
        if x.isNetwork ~= false then networked = networked + 1 end
    end
    eq(networked, 0, 'and neither of them is networked')

    eq(#entsOfModel(A.chuteModel), 1, 'the canopy exists')
    eq(#entsOfModel(flareProp()), 0,
        'and no flare PROP is created on the projectile route -- no model '
        .. 'glows, which is the whole of the third attempt')
    ok(#anims >= 1, 'and the canopy deploy anim is played')

    -- NOTHING IS ATTACHED TO ANYTHING. The canopy is positioned from the same
    -- solver as the crate; an ATTACH_ENTITY_TO_ENTITY would be a second
    -- mechanism deciding where a part of the drop is, and this suite could not
    -- see it at all.
    eq(#attaches, 0, 'and nothing is attached to anything')
end

describe('client: the falling crate lights real flares')
do
    -- ═══ WHAT A TEST CAN AND CANNOT SAY ABOUT A PROJECTILE ═══
    --
    -- It has no handle. Nothing in the game reports whether it rendered, so
    -- nothing here pretends to. What this block pins is every fact the first
    -- two attempts got wrong and nobody could see: that the call is made at
    -- all, with the configured weapon, at the two positions the crate's faces
    -- are at, with the arguments that stop it flying away.
    clientReset()
    announce()
    render()

    eq(#shots, 2, 'one flare on each side, at the release')
    for _, s in ipairs(shots) do
        eq(s.weapon, A.flareWeapon, 'the configured weapon')
        eq(s.owner, 0, 'owned by nobody, so nothing it does is attributed')
        eq(s.damage, 0, 'and it does no damage')
        eq(s.speed, A.flareSpeed, 'at the configured speed')
        -- NEGATIVE, which is idiomatic across every resource that fires a flare
        -- in place. Asserted as a SIGN rather than only as "whatever the config
        -- says", because a config edited to a positive number would otherwise
        -- pass this block unchanged.
        ok((s.speed or 0) < 0, 'and that speed is negative')
        -- ═══ THE SEPARATION IS THE ANSWER TO "A PROJECTILE IS BALLISTIC" ═══
        --
        -- Two coincident points give the shot no direction to travel in, so the
        -- flare stands still. Non-zero because the reference resource records
        -- that identical coords leave a flare that never removes itself -- and
        -- the engine's own expiry is the only reason we are allowed to make
        -- something we hold no handle to.
        local sep = math.sqrt((s.x1 - s.x2) ^ 2 + (s.y1 - s.y2) ^ 2
                              + (s.z1 - s.z2) ^ 2)
        ok(sep > 0.0, 'the shot has a real separation, so the engine expires it')
        ok(sep < 0.01, 'and a tiny one, so it does not fly anywhere')
    end

    -- ON OPPOSITE SIDES, which "each one is 1.1m from the crate" does not say.
    -- Both flares stacked on one side satisfies every distance check, and a
    -- mutation pass proved exactly that by flipping the sign and surviving.
    local rec = drops and nil
    ok(near(BR.Dist(shots[1].x1, shots[1].y1, shots[2].x1, shots[2].y1),
            A.flareOffset.x * 2.0, 0.001),
        'and they are a full diameter apart -- one offset, two signs')

    -- ═══ THE CADENCE, WHICH IS WHAT MAKES A TRAIL RATHER THAN A DOT ═══
    --
    -- A fired flare stands where it was lit while the crate falls away from it.
    -- Firing once would leave one flare at the release altitude and a crate
    -- 170m below it; firing EVERY FRAME would light 1800 of them. Neither is
    -- what the owner asked for.
    render()
    render()
    eq(#shots, 2, 'a second frame within the cadence lights nothing new')

    gameMs = gameMs + (A.flareFallRefireMs or 3000)
    render()
    eq(#shots, 4, 'and the cadence lights another pair when it comes due')

    -- ...and the new pair is LOWER, because the crate has fallen. That is the
    -- burning column, and it is the only assertion here that says the trail is
    -- a trail.
    ok(shots[3].z1 < shots[1].z1,
        'lit lower than the last pair, because the crate fell between them')

    -- NOTHING IS HELD, so there is nothing to leak and nothing to tear down.
    eq(entCount(), 2, 'and still only a crate and a canopy exist')

    -- ═══ AND THE FALLBACK IS NEGATIVE TOO ═══
    --
    -- `A.flareSpeed or -1.0` is only reached when the config value is missing,
    -- which it never is -- so a mutation to that literal survived the whole
    -- suite. A config key can be deleted by an override or a bad merge, and the
    -- fallback is what runs then.
    clientReset()
    local realSpeed = A.flareSpeed
    A.flareSpeed = nil
    announce()
    render()
    ok(#shots >= 1, 'a missing flareSpeed still fires')
    ok((shots[1].speed or 0) < 0,
        'and the built-in fallback is negative, like every resource that does '
        .. 'this')
    A.flareSpeed = realSpeed
end

--- The delivery plane's HANDLE, not its row. The terrain block below reads the
--- z that was written to it, which needs the key.
local function planeHandle()
    for h in pairs(vehicles) do return h end
    return nil
end

describe('client: the crate exists on the frame its flares are lit')
do
    -- ═══ THE ARGUMENT THAT DIAGNOSED "THE LOOSE FLARES DROP BEFORE THE CARGO"
    --     (owner, 2026-08-23) ═══
    --
    -- "we need to fix the delay between when the cargobob flies over and when
    -- the cargo drops. It seems that the loose flares drop before the cargo -
    -- they should all be at once. The flares start dropping at the perfect time
    -- for the cargo to drop."
    --
    -- THEY ARE NOT TWO TIMINGS THAT COULD DRIFT. place() writes the crate's
    -- coordinates and THEN hands client/flares.lua the two positions beside it,
    -- and place() only ever runs on a frame where the crate object exists. This
    -- block is that sentence as code: a flare at the right moment PROVES a crate
    -- at the right moment, which is what turns "the cargo is late" into "the
    -- cargo is not being drawn".
    clientReset()
    eq(#shots, 0, 'nothing is lit before the drop')
    eq(entCount(), 0, 'and nothing is built')

    announce(170.0)
    render()

    local crates = entsOfModel(A.crateProp)
    eq(#crates, 1, 'one crate exists after one frame')
    eq(#shots, 2, 'and its pair of flares was lit on that same frame')

    local mv = crateMove()
    ok(mv ~= nil, 'the crate was placed on it too')
    if mv then
        ok(near(shots[1].z1, mv.z, 1e-6),
            'and the flares are at the crate\'s own height, not somewhere above it',
            ('flare %.3f, crate %.3f'):format(shots[1].z1, mv.z))
        -- THE AUTHORED HEIGHT, NOT THE PROBED ONE (2026-08-23). The rig's POI
        -- is authored at 30 and its ground probes to 12, and the release end of
        -- BR.AirdropCrateZ is the authored number on purpose: the aircraft flies
        -- off `rec.gz` too, so the box leaves exactly planeAltAbove beneath it
        -- however wrong config/map.lua's first pass was. The probed 12 is where
        -- it LANDS, which the descent block below checks.
        ok(near(mv.z, 30.0 + 170.0, 1e-6),
            'which is the full release altitude -- nothing has fallen yet',
            mv.z)
    end

    -- ═══ SO THE FIX IS THE DRAW DISTANCE, AND HERE IS THE CALL ═══
    --
    -- The box comes into being 170m up. A projectile flare is visible from
    -- there because it carries the engine's own light and corona; a Cargobob is
    -- visible because it is a vehicle. A wooden box is a small prop with a small
    -- authored LOD distance and starts being drawn most of the way down, which
    -- reads exactly as "the cargo dropped late".
    --
    -- There is no getter for SET_ENTITY_LOD_DIST, so what can be asserted is
    -- what /brairdrop can print: the call was made, on that handle, with that
    -- number.
    eq(lods[crates[1]], A.propLodDist, 'the crate is asked to draw from up there')
    local chutes = entsOfModel(A.chuteModel)
    eq(#chutes, 1, 'and so is the canopy over it')
    eq(lods[chutes[1]], A.propLodDist, 'at the same distance')
    local ph = planeHandle()
    ok(ph ~= nil, 'and the aircraft, whose run-in starts 540m out')
    if ph then eq(lods[ph], A.propLodDist, 'carries it too') end

    -- A BUILD WITHOUT THE BINDING LOSES THE DRAW DISTANCE, NOT THE DROP. Same
    -- rule as every other native this file cannot prove is present.
    clientReset()
    local realLod = SetEntityLodDist
    SetEntityLodDist = nil
    announce(170.0)
    render()
    eq(#entsOfModel(A.crateProp), 1,
        'no SetEntityLodDist on this build still builds the crate')
    eq(#shots, 2, 'and still lights its flares')
    SetEntityLodDist = realLod
end

describe('client: nothing on the render path waits for an asset')
do
    -- ═══ A SYNCHRONOUS ASSET WAIT ON A PER-FRAME CALLBACK (2026-08-23) ═══
    --
    -- /brperf: one pass of `airdrop.render` in 113,237 at 55ms, every other
    -- sample in the registry zero, total == peak. BR.Loop.step's stopwatch reads
    -- GetGameTimer either side of the callback and GetGameTimer is LATCHED PER
    -- FRAME (4864976), so a non-zero reading means the call SPANNED A FRAME --
    -- it yielded, or the engine re-latched while it was on the stack -- and says
    -- nothing about how much work it did.
    --
    -- THAT SAMPLE IS NOT PROOF ABOUT THIS FILE. The owner adds: "that even
    -- happens on matches which haven't had airdrops", and with no record the
    -- callback returns on its first line and cannot span anything.
    --
    -- WHAT IS WRONG REGARDLESS is that three things reachable from place() CAN
    -- yield, all in client/flares.lua and all the same shape -- a
    -- `Citizen.Wait(50)` inside a bounded stream loop: loadWeapon (projectile
    -- route), loadModel and loadPtfx (object route). That is a hitch waiting for
    -- the first drop of every session, and this block is the fix as code: what
    -- has been requested, and when.
    clientReset()
    local sited = announceSited()
    render()

    -- NOT ARMED. No aircraft, no crate, no flare -- and every stream already
    -- asked for. This is the frame the old code did nothing on.
    ok(not BR.AirdropArmed(sited), 'the drop is announced and not yet armed')
    eq(entCount(), 0, 'so nothing is built')
    eq(#shots, 0, 'and nothing is lit')
    ok(next(weaponAssets) ~= nil,
        'but the flare weapon asset has already been requested')
    local asked = {}
    for _, m in ipairs(modelRequests) do asked[m] = true end
    ok(asked[GetHashKey(A.crateProp)], 'and the crate model')
    ok(asked[GetHashKey(A.chuteModel)], 'and the canopy model')

    -- ═══ AND THE RELEASE FRAME ASKS FOR NOTHING AT ALL ═══
    --
    -- This is the assertion that fails if somebody moves a stream back onto the
    -- release: the frame the crate, the canopy and both flares appear on must
    -- make no request of any kind.
    armSited(sited)
    render()                          -- the run-in
    local beforeRelease = #modelRequests
    gameMs = gameMs + A.planeLeadMs
    render()                          -- the release itself
    eq(#modelRequests, beforeRelease,
        'the release frame requests no model -- everything it needs is resident')
    eq(#entsOfModel(A.crateProp), 1, 'the crate is built on it')
    eq(#entsOfModel(A.chuteModel), 1, 'and the canopy')
    eq(#shots, 2, 'and both flares are lit on the same frame')

    -- ═══ THE OBJECT ROUTE IS PRIMED TOO ═══
    --
    -- /brflare can put the match on it at any moment, so "the projectile route
    -- is the default" is not a reason to leave the other one able to stall a
    -- frame. Its two streams are a prop model and a ptfx asset.
    clientReset()
    A.flareRoute = 'object'
    local obj = announceSited()
    render()
    local askedObj = {}
    for _, m in ipairs(modelRequests) do askedObj[m] = true end
    ok(askedObj[GetHashKey(A.flareModel)],
        'the object route\'s flare model is requested at the announcement too')
    eq(entCount(), 0, 'with nothing built yet')
    armSited(obj)
    gameMs = gameMs + A.planeLeadMs
    render()
    eq(#entsOfModel(A.flareModel), 2, 'and its two flares arrive with the crate')
    A.flareRoute = 'projectile'
end

describe('client: the aircraft holds one height, and no probe decides it')
do
    -- ═══ THE SAME QUESTION THE CORRIDOR BLOCK ASKED, OF THE MODEL THAT
    --     REPLACED IT (owner, 2026-08-23) ═══
    --
    -- The corridor version of this block set `ground.at` to a ridge and checked
    -- the aircraft rose over it. It passed, and the feature did nothing in game,
    -- because the rig answers every probe and a real client answers almost none
    -- of them at 810m. THAT IS THE CASE THIS RIG STRUCTURALLY CANNOT TEST, so
    -- the height is no longer a probe's business at all: it comes from
    -- BR.Config.Map.POIs, which is in memory on both sides.
    --
    -- The rig's drop is the sited one at (100, 200) with the POI authored at
    -- z 30 and heading 90 -- so forward is -x, and the run-in comes in from the
    -- +x side.
    clientReset()
    -- A summit ON the flight line, 300m up the run-in. Nothing about the ground
    -- probe is involved; this is a table entry.
    BR.Config.Map.POIs = {
        { id = 'ridge', x = 100.0 + 300.0, y = 200.0, z = 500.0,
          radius = 60.0 },
    }

    local rec = announceSited()
    armSited(rec)
    render()

    local ph = planeHandle()
    ok(ph ~= nil, 'the aircraft is on its run-in')
    if ph then
        ok(near(vehicles[ph].z, 500.0 + (A.planeTerrainClearance or 60.0), 1e-6),
            'and it is flying 60m clear of the ridge rather than through it',
            vehicles[ph].z)
        -- ...WHICH IT WOULD NOT HAVE BEEN. The nominal height is the authored
        -- ground at the DROP POINT plus planeHeight, and that is 220m inside the
        -- rock here.
        ok(30.0 + A.planeHeight < 500.0,
            'the nominal height really is below the ridge -- this test would '
            .. 'pass by accident otherwise')
    end

    -- ═══ AND IT DOES NOT COME BACK DOWN AT THE RELEASE ═══
    --
    -- This is the assertion that INVERTS. The corridor was clipped at tRelease
    -- so the lift vanished exactly as the crate left, and the release geometry
    -- was recovered by that collapse. A constant does not collapse: the
    -- aircraft is at the same height on the release frame as on the first one,
    -- and the geometry is recovered by arithmetic instead -- the crate leaves at
    -- `rec.gz + altitude` and the aircraft holds `rec.gz + planeHeight`, so the
    -- gap is planeAltAbove wherever the pair happen to be.
    local before = ph and vehicles[ph].z
    gameMs = gameMs + A.planeLeadMs
    render()
    if ph and vehicles[ph] then
        ok(near(vehicles[ph].z, before, 1e-6),
            'at the release it is at exactly the height it started at',
            vehicles[ph].z)
        local mv = crateMove()
        ok(mv and near(mv.z, 30.0 + A.altitude, 1e-6),
            'and the crate leaves from the authored release height',
            mv and mv.z)
        ok(mv and near((30.0 + A.planeHeight) - mv.z,
                       A.planeAltAbove or 25.0, 1e-6),
            'which is exactly planeAltAbove under the nominal flight height')
    end

    -- FLAT GROUND IS NOT A LIFT. Nothing authored under the route must write the
    -- nominal height and nothing else -- otherwise this feature is a permanent
    -- altitude increase wearing a table.
    clientReset()
    local flat = announceSited()
    armSited(flat)
    render()
    local ph2 = planeHandle()
    ok(ph2 and near(vehicles[ph2].z, 30.0 + A.planeHeight, 1e-6),
        'with nothing authored under the route it flies exactly 250m up',
        ph2 and vehicles[ph2].z)

    -- A POI OFF THE BEARING IS NOT UNDER THE ROUTE. Same summit, moved to the
    -- side: the aircraft never crosses it, so it must not lift for it.
    clientReset()
    BR.Config.Map.POIs = {
        { id = 'aside', x = 100.0, y = 200.0 + 900.0, z = 500.0,
          radius = 60.0 },
    }
    local aside = announceSited()
    armSited(aside)
    render()
    local ph4 = planeHandle()
    ok(ph4 and near(vehicles[ph4].z, 30.0 + A.planeHeight, 1e-6),
        'a summit 900m off the bearing does not raise the aircraft',
        ph4 and vehicles[ph4].z)

    -- ═══ AND A PROBE THAT ANSWERS NOTHING NO LONGER MOVES THE AIRCRAFT AT ALL
    --     ═══
    --
    -- This case used to be the fail-open path and it was the whole flight in
    -- practice. It is now unreachable by construction: the height is solved from
    -- the record and the table, so a blind client flies the identical route. The
    -- 0 shape still matters for the CRATE's landing height, which is the probe's
    -- remaining job -- 0 is truthy in Lua and this project has shipped that six
    -- times.
    clientReset()
    ground.ok = 0
    local blind = announceSited()
    armSited(blind)
    render()
    local ph3 = planeHandle()
    ok(ph3 ~= nil, 'a blind probe still builds the aircraft')
    if ph3 then
        ok(near(vehicles[ph3].z, (blind.gz or 0.0) + A.planeHeight, 1e-6),
            'and flies it at exactly the same height a sighted one gets',
            vehicles[ph3].z)
    end
end

describe('client: touchdown leaves the fired flares to the engine')
do
    clientReset()
    announce()
    render()
    local before = #fxStopped
    local lit = #shots

    gameMs = gameMs + A.descentMs
    render()

    eq(entCount(), 0, 'every object of ours is gone at touchdown')
    eq(#fxStopped - before, 0,
        'and no particle is stopped, because the projectile route started none')
    ok(#shots >= lit, 'the flares already lit are not un-fired')
    -- The engine expires them on AMMO_FLARE's own 62.5s clock. Nothing here
    -- deletes an object it did not create, which is the reason the cleanup
    -- loop the reference resources use -- GetClosestObjectOfType with a radius
    -- -- is deliberately absent: on this map it would just as happily delete a
    -- flare somebody else lit.
end

describe('client: a weapon asset that will not stream costs nothing')
do
    -- Best-effort, exactly as the canopy's deploy anim is. A drop that failed
    -- to arrive because a weapon asset was missing is a match without its
    -- airdrop, which is far worse than a crate with no flares.
    clientReset()
    weaponLoads = 0
    announce()
    render()
    eq(#shots, 0, 'nothing is fired')
    -- ═══ AND IT IS NOT EVEN ATTEMPTED, WHICH IS THE 2026-08-23 CHANGE ═══
    --
    -- It used to be attempted, fail inside client/flares.lua and be counted
    -- there -- and getting to that counter meant walking into loadWeapon's
    -- `Citizen.Wait(50)` loop ON THE RENDER PATH, which is a spanned frame and
    -- is what /brperf measured at 55ms. primeAssets asks for the asset at the
    -- announcement instead and place() refuses to call flares.lua at all until
    -- it has one. A frame that cannot light a flare lights none; it does not
    -- wait five seconds to find that out.
    --
    -- THE DIAGNOSTIC DID NOT GO AWAY, IT MOVED AND GOT BETTER. `BR.Flare.failed`
    -- said "something went wrong lighting a flare"; /brairdrop now names which
    -- half is missing before anything is attempted.
    local printed = {}
    local realPrintFn = print
    print = function(s) printed[#printed + 1] = tostring(s) end
    commands['brairdrop'](0, {}, '')
    print = realPrintFn
    ok(table.concat(printed, '\n'):find('flares ready false', 1, true) ~= nil,
        'and /brairdrop says why, before anything is attempted')
    eq(entCount(), 2, 'but the crate and its canopy still arrive')

    gameMs = gameMs + A.descentMs
    render()
    eq(entCount(), 0, 'and the drop still tears down cleanly')
end

describe('client: the object route still works, and is the one with a handle')
do
    -- ═══ WHY THIS ROUTE SURVIVES AT ALL ═══
    --
    -- A projectile can be asked nothing. A looped ptfx handle can be asked
    -- whether it is alive. When the owner reports "no flares" again, this is
    -- the route that tells "the client is not drawing flares" apart from "the
    -- client is drawing flares that do not glow" -- two different bugs with one
    -- symptom, which is what cost the last two rounds.
    clientReset()
    A.flareRoute = 'object'
    announce()
    render()

    eq(#shots, 0, 'nothing is fired on this route')
    eq(#entsOfModel(flareProp()), 2, 'a flare prop on each side')
    eq(#fxStarted, 2, 'with one looped effect on each')

    local flares = entsOfModel(flareProp())
    local onFlare = 0
    for _, f in ipairs(fxStarted) do
        eq(f.name, A.flarePtfxName, 'the configured effect')
        for _, hnd in ipairs(flares) do
            if f.ent == hnd then onFlare = onFlare + 1 end
        end
    end
    eq(onFlare, 2,
        'anchored to the FLARES rather than started at a coordinate -- an '
        .. 'emitter that does not ride the fall leaves no trail')

    -- USE_PARTICLE_FX_ASSET IS PER CALL. Asserted because the symptom of
    -- missing it is not an error: the effect resolves against whatever asset
    -- was named last, which on a quiet frame is nothing at all.
    eq(#fxAssetUsed, 2, 'the asset is re-asserted before every start')

    -- ...and both are stopped BEFORE the entities they are anchored to are
    -- deleted. A looped effect outlives its entity -- that is what looped means
    -- -- so the other order leaves an emitter running in mid-air forever.
    local n = #fxStopped
    gameMs = gameMs + A.descentMs
    render()
    eq(#fxStopped - n, 2, 'and both are stopped on touchdown')
    eq(#entsOfModel(flareProp()), 0, 'with the flares deleted')
end

describe('client: a particle asset that will not stream costs nothing')
do
    clientReset()
    A.flareRoute = 'object'
    ptfxLoaded = 0
    announce()
    render()
    eq(#fxStarted, 0, 'no effect is started')
    eq(#entsOfModel(flareProp()), 2, 'but the flares are still there')
    eq(entCount(), 4, 'and so is everything else')

    -- ═══ A FAILED START ANSWERS -1, AND THE OLD CHECK LOOKED FOR 0 ═══
    --
    -- Cfx's own ParticleEffect wrapper documents the handle as "-1 when this
    -- ParticleEffect is not active", and its start path stores the handle only
    -- if `handle ~= -1 and DoesParticleFxLoopedExist(handle)`. The first flare
    -- attempt tested against 0 -- the right instinct aimed at the wrong number
    -- -- so a -1 was stored as a live handle and the diagnostic reported two
    -- healthy flares over an empty sky.
    --
    -- BOTH SENTINELS, because Cfx's looped wrapper says -1 and its non-looped
    -- one says 0, and when the engine's own bindings disagree the only safe
    -- answer is to refuse both.
    for _, failValue in ipairs({ -1, 0 }) do
        clientReset()
        A.flareRoute  = 'object'
        ptfxHandle    = 0     -- the rig's "next start fails" switch
        ptfxFailValue = failValue
        announce()
        render()
        eq(#fxStarted, 2, ('the start was attempted (fails with %d)')
            :format(failValue))
        local before = #fxStopped
        gameMs = gameMs + A.descentMs
        render()
        eq(#fxStopped - before, 0,
            ('and a %d handle is never stored, so never stopped')
                :format(failValue))
    end
    ptfxFailValue = -1

    -- THE OTHER WAY TO FAIL, which nothing checked at all: a handle that is
    -- neither -1 nor 0 and is still DEAD. Only DoesParticleFxLoopedExist can
    -- tell, which is why Cfx asks it as well as the sentinel.
    clientReset()
    A.flareRoute = 'object'
    fxAlive = false
    announce()
    render()
    eq(#fxStarted, 2, 'a plausible-looking handle came back')
    local before2 = #fxStopped
    gameMs = gameMs + A.descentMs
    render()
    eq(#fxStopped - before2, 0,
        'and it is still not stored, because the effect is not running')
end

describe('client: a landed box never gets flares, however long anybody waits')
do
    -- ═══ THE OWNER ASKED FOR LANDED FLARES, PLAYED THEM, AND ASKED FOR THEM
    --     BACK OUT. THIS BLOCK IS THE SECOND HALF. ═══
    --
    -- 2026-08-22: "there should be flares on the husk too fwiw."
    -- 2026-08-23: "Seems the husk keeps getting more and more flares
    --   indefinitely though... If we drop the husk flares and keep the
    --   free-falling ones I'd be happy with that."
    --
    -- WHY IT ACCUMULATED, because that is what this is really pinning. A
    -- projectile flare is lit AT A COORDINATE and burns where it was lit, and we
    -- hold no handle to delete one. Against a FALLING crate the cadence paints a
    -- column down the descent path and each flare expires on its own -- the part
    -- the owner loves, pinned in 'client: the falling crate lights real flares'.
    -- Against a box that has STOPPED, the same cadence stacked a new pair on the
    -- same spot every 45 seconds until the match ended.
    --
    -- THE ONLY HONEST TEST OF "IT NEVER HAPPENS" IS A CLOCK THAT RUNS. Asserting
    -- zero on one pass would also pass with the landed job merely not due yet,
    -- which is the state the bug spent its first 45 seconds in.
    clientReset()

    -- The registry job that did this is gone, and its name going with it is
    -- part of the removal: a re-registered 'flares.landed' is how this comes
    -- back without anybody meaning it to.
    eq(loops['flares.landed'], nil,
        'there is no landed-flare job in the loop registry at all')
    eq(BR.Flare.landedStatus, nil,
        'and nothing left exporting what it was doing')

    -- A crate on the ground, streamed in, exactly as client/loot.lua would have
    -- presented it -- and now with nothing that asks about it.
    lootBox = 4101
    ents[4101] = { model = A.huskProp, x = 5.0, y = 6.0, z = 7.0 }

    local shotsBefore = #shots
    local entsBefore  = entCount()
    boxAsked = 0

    -- TEN MINUTES OF A MATCH, at the cadence that used to fire. The old pass ran
    -- at 10Hz off BR.Loop.TICK and re-fired every 45s, so this window is about
    -- thirteen pairs it would have produced.
    for _ = 1, 20 do
        gameMs = gameMs + 45000
        for _, fn in pairs(loops) do fn() end
    end

    eq(#shots - shotsBefore, 0,
        'ten minutes pass over a landed crate and not one flare is fired at it')
    eq(entCount() - entsBefore, 0,
        'and no flare prop is built either -- the box is still the only entity')
    -- THE STRONGER FORM OF THE SAME CLAIM. Zero flares is also what a landed
    -- pass that ran and failed would produce; zero QUESTIONS is only what a
    -- landed pass that does not exist produces.
    eq(boxAsked, 0,
        'because nothing asked where the box was -- the accessor has no callers')

    -- ═══ AND NOT ON THE OBJECT ROUTE EITHER ═══
    --
    -- The object route is one console command away and is what gets reached for
    -- when the projectile route shows nothing, so "no landed flares" has to be
    -- true on both or the feature comes back the moment somebody debugs it.
    A.flareRoute = 'object'
    for _ = 1, 20 do
        gameMs = gameMs + 45000
        for _, fn in pairs(loops) do fn() end
    end
    eq(#entsOfModel(flareProp()), 0,
        'and the object route builds none on it either')
    A.flareRoute = 'projectile'

    -- ═══ THE HUSK IS THE CASE THE OWNER NAMED, SO IT IS NAMED HERE ═══
    --
    -- A sealed crate becoming its husk is a NEW entity handle for the SAME
    -- registry entry. That handle change was the trigger the old pass followed;
    -- nothing follows it now.
    ents[4101] = nil
    lootBox = 4102
    ents[4102] = { model = A.huskProp, x = 5.0, y = 6.0, z = 7.0 }
    for _ = 1, 20 do
        gameMs = gameMs + 45000
        for _, fn in pairs(loops) do fn() end
    end
    eq(#shots - shotsBefore, 0,
        'and the husk it becomes collects none, which is the exact sentence '
        .. 'the owner reversed')
    eq(boxAsked, 0, 'and the handle change was never even looked at')
end

describe('client: the audio priority receipt is honest about what it knows')
do
    -- Owner, 2026-08-22: "Sure let's use the audio priority native, but we need
    -- a way to validate it especially since nobody uses it."
    --
    -- THE NATIVE RETURNS void AND HAS NO GETTER. Nothing can read a vehicle's
    -- audio priority back, so the receipt says what was asked and whether the
    -- call went through, and claims nothing about the engine agreeing. A test
    -- that asserted more than that would be inventing the validation the owner
    -- asked for.
    clientReset()
    announce()
    render()

    eq(#audioCalls, 1, 'the aircraft is asked for a priority once, at spawn')
    eq(audioCalls[1].pri, A.planeAudioPriority, 'the configured one')
    eq(audioCalls[1].pri, 2, 'which is MAX -- 2, not the higher-looking 3')
    eq(audioCalls[1].veh, onePlane() and (function()
        for h in pairs(vehicles) do return h end
    end)() or nil, 'on the aircraft that was just built')

    local r = BR.Airdrop.setPlaneAudio(1, 2)
    eq(r.applied, true, 'a successful call reports applied')
    eq(r.asked, 2, 'and what it asked for')

    -- nil means "do not ask", which is how the owner turns the whole thing off
    -- for the A half of an A/B.
    local off = BR.Airdrop.setPlaneAudio(1, nil)
    eq(off.applied, false, 'a nil priority asks for nothing')

    -- ═══ A BUILD WITHOUT THE BINDING MUST SAY SO RATHER THAN THROW ═══
    --
    -- Essentially nobody uses this native, so "it does not exist here" is a
    -- live possibility and it must be distinguishable from "it did nothing".
    local real = SetAudioVehiclePriority
    SetAudioVehiclePriority = nil
    local missing = BR.Airdrop.setPlaneAudio(1, 2)
    SetAudioVehiclePriority = real
    eq(missing.applied, false, 'a missing native is reported, not thrown')
    ok(tostring(missing.why):find('does not exist', 1, true) ~= nil,
        'and it says which of the two failures it was')
end

describe('client: the descent')
do
    clientReset()
    local rec = announce(260.0, 30000)
    render()
    local last = crateMove()
    ok(last ~= nil, 'the crate is positioned')
    -- ═══ THE RELEASE END IS AUTHORED AND THE LANDING END IS PROBED
    --     (2026-08-23) ═══
    --
    -- It used to be `ground.z + alt` at BOTH ends, which is why a crate could
    -- hang below the Cargobob that dropped it: the aircraft flies off the
    -- authored `rec.gz` -- the only height that answers at a kilometre -- and
    -- the probe here says 12 where the POI is authored at 30. The box now leaves
    -- from 30 + 260 and arrives at the probed 12, interpolating between them.
    ok(near(last.z, rec.gz + 260.0, 0.001),
        'starting 260m above the AUTHORED ground, where the aircraft is')
    ok(near(last.x, rec.x, 0.001), 'over the POI')

    gameMs = gameMs + 15000
    render()
    last = crateMove()
    -- ═══ AND THE CLIENT DRAWS THE CURVE, NOT THE CLOCK (2026-08-28) ═══
    --
    -- This used to be the midpoint of the two anchors, which held only while the
    -- descent was linear. The point of the assertion has not changed -- "the box
    -- on screen is where the solver says" -- so it is written against the solver
    -- rather than against a number that happened to equal it.
    ok(near(last.z, BR.AirdropCrateZ(rec, gameMs, ground.z, A), 0.001),
        'the crate is exactly where the shared solver puts it', last.z)
    ok(last.z < (rec.gz + 260.0 + ground.z) / 2,
        ('and past the halfway point already, because most of the fall happens '
         .. 'at the cruise rate -- %.1f against %.1f')
            :format(last.z, (rec.gz + 260.0 + ground.z) / 2))

    -- EVERY PART FALLS WITH IT. The canopy is a separate object, so "the crate
    -- is at the right height" says nothing about it -- and a canopy left at the
    -- release altitude while the crate falls out from under it is exactly what
    -- an attachment would have hidden.
    local crateZ = last.z
    local chute = entsOfModel(A.chuteModel)[1]
    ok(chute ~= nil and near(ents[chute].z,
        crateZ + (A.chuteOffset.z or 0.1), 0.001),
        'the canopy is directly over it, at its own offset')

    -- AND THE FLARES ARE LIT AT THE CRATE'S HEIGHT, not at the release
    -- altitude. On the projectile route there is no flare entity to inspect --
    -- the assertion is on the SHOT, which is the only record that exists.
    local pair = { shots[#shots - 1], shots[#shots] }
    for _, s in ipairs(pair) do
        ok(near(s.z1, crateZ + (A.flareOffset.z or 0.0), 0.001),
            'each flare is lit at the crate\'s height, not where it started')
        ok(near(BR.Dist(s.x1, s.y1, rec.x, rec.y), A.flareOffset.x, 0.001),
            'and out to the side by exactly the configured offset')
    end

    -- ON OPPOSITE SIDES, which "each one is 1.1m from the crate" does not say
    -- -- both flares on the same side satisfy every check above, and a mutation
    -- pass proved it by flipping the sign and surviving. Left and right is the
    -- owner's whole instruction.
    ok(near(BR.Dist(pair[1].x1, pair[1].y1, pair[2].x1, pair[2].y1),
            A.flareOffset.x * 2.0, 0.001),
        'and they are a full diameter apart -- one offset, two signs',
        ('%.3f apart'):format(BR.Dist(pair[1].x1, pair[1].y1,
                                      pair[2].x1, pair[2].y1)))

    -- Touchdown: the props go, the blip stays.
    gameMs = gameMs + 15000
    render()
    eq(oneEnt(), nil, 'the falling crate is deleted on touchdown')
    eq(entCount(), 0, 'and so is every part of it')
    ok(oneBlip() ~= nil, 'but the blip is still up')

    -- ...AND IT OUTLIVES THE LANDING BY FAR LONGER THAN IT USED TO. The old
    -- rule ended the blip a minute after touchdown, which is what the owner ran
    -- out of on 2026-08-22 ("if nobody arrives fast enough, the blip goes away
    -- and they have no idea where the drop is"). Nobody has opened this crate,
    -- so the ceiling is what ends it -- four minutes from the ANNOUNCEMENT.
    gameMs = gameMs + 60000
    render()
    ok(oneBlip() ~= nil,
        'still up a minute after landing, where the old rule ended it')

    local rec = nil
    for _, b in pairs(blips) do rec = b break end
    ok(rec ~= nil, 'and it is the same blip, not a rebuilt one')

    -- Straight to the ceiling.
    gameMs = gameMs + A.blipMaxMs
    render()
    eq(oneBlip(), nil, 'and gone once four minutes from the announcement pass')
end

describe('client: BOOL natives, both wrong shapes')
do
    -- THE FOUR-TIMES BUG, in both directions at once.
    --
    -- A native declared BOOL may answer 1 rather than true, so `v == true` is
    -- false for a yes. And IN LUA 0 IS TRUTHY, so `if v then` is true for a no.
    -- A fix has to survive both rows or it has only moved the fault.

    -- ═══ MEASURED AT TOUCHDOWN, NOT AT THE RELEASE (2026-08-23) ═══
    --
    -- The release height is authored now and the probe has nothing to do with
    -- it, so asking about the first frame would give the same answer for a probe
    -- that said yes, a probe that said no and a probe that was never called.
    -- The LANDING is where the probe's answer lives, so that is where both rows
    -- below are read -- one frame short of tLand, because at tLand the crate is
    -- deleted and there is nothing left to measure.
    local function crateNearTouchdown(span)
        gameMs = gameMs + span - 1
        render()
        return crateMove()
    end

    -- The probe says NO, with a zero. A guard written `if ok then` would take
    -- the zero as a yes and fall toward the probe's garbage z instead of the
    -- POI's authored height.
    clientReset()
    ground.ok, ground.z = 0, -9999.0
    local rec = announce(260.0, 30000)
    render()
    local last = crateNearTouchdown(30000)
    ok(last and last.z > rec.gz - 1.0,
        'a probe answering 0 is a refusal, so the POI height stands in',
        last and last.z)

    -- The probe says YES, with a one. A guard written `ok == true` would
    -- discard a perfectly good answer.
    clientReset()
    ground.ok, ground.z = 1, 44.0
    announce(260.0, 30000)
    render()
    last = crateNearTouchdown(30000)
    ok(last and near(last.z, 44.0, 0.05),
        'a probe answering 1 is an answer, and the crate lands on it',
        last and last.z)

    -- HasNamedPtfxAssetLoaded gets the same pair, on the OBJECT route, which is
    -- the only one that starts a particle at all. A 0 must be a refusal...
    clientReset()
    A.flareRoute = 'object'
    ptfxLoaded = 0
    announce()
    render()
    eq(#fxStarted, 0, 'a ptfx asset answering 0 starts nothing')

    -- ...and a 1 must be an answer.
    clientReset()
    A.flareRoute = 'object'
    ptfxLoaded = 1
    announce()
    render()
    eq(#fxStarted, 2, 'and one answering 1 starts both trails')

    -- HasWeaponAssetLoaded is the sixth BOOL native here and the newest, so it
    -- gets the pair too. This is the one the whole projectile route hangs off:
    -- a 0 read as truthy would have us firing against an unstreamed asset,
    -- which is the documented cause of the native answering nothing at all.
    clientReset()
    weaponLoads = 0
    announce()
    render()
    eq(#shots, 0, 'a weapon asset answering 0 fires nothing')

    clientReset()
    weaponLoads = 1
    announce()
    render()
    eq(#shots, 2, 'and one answering 1 lights both flares')

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

describe('client: a flare model that does not load never costs the drop')
do
    -- ═══ THE 2026-08-21 BUG, AS A TEST ═══
    --
    -- The config named `prop_flare_01a`. There is no such model in GTA V --
    -- there is a `prop_flare_01` and a `prop_flare_01b` and no `_01a`. So
    -- IsModelValid refused it, loadModel returned false, and the whole flare
    -- branch (props AND particles, both behind one `if`) never ran. The owner
    -- saw no flares and no smoke, and nothing said why.
    --
    -- THE PROJECTILE ROUTE CANNOT HAVE THAT BUG AT ALL -- it loads no model --
    -- which is worth stating plainly, because it is the strongest argument for
    -- the route beyond the glow itself. This block therefore drives the OBJECT
    -- route, where the failure mode still exists and still has to be survivable.
    --
    -- A test cannot know which names are real. It CAN prove that a bad one no
    -- longer deletes the airdrop with it.
    clientReset()
    A.flareRoute = 'object'
    validModels = { [A.crateProp] = true, [A.chuteModel] = true,
                    [A.planeModel] = true, [A.planePilot] = true }
    announce()
    render()
    eq(#entsOfModel(flareProp()), 0,
        'the flare model does not load on this build, so there are no flares')
    ok(oneEnt() ~= nil, 'but the crate is still falling')
    eq(#entsOfModel(A.crateProp), 1, 'and it is the crate')
    eq(#entsOfModel(A.chuteModel), 1, 'under its canopy')

    -- ...and nothing tries to stop a particle that was never started.
    local before = #fxStopped
    gameMs = gameMs + A.descentMs
    render()
    eq(#fxStopped - before, 0, 'and teardown has no emitter to stop')
end

describe('client: every falling part is drawn at its configured size')
do
    -- Owner, 2026-08-22: "The parachute and crate props (including husk) should
    -- be 2x larger and the parachute should be 2.5x larger please."
    --
    -- Owner, 2026-08-23, having played it: "we need to tweak how the prop
    -- scaling works for the crate as it currently clips. We may need to drop
    -- scaling altogether." and "the parachute scaling works great - let's keep
    -- that."
    --
    -- THERE IS NO SetEntityScale IN GTA V (#166), so this is the transform
    -- matrix -- which the owner has now confirmed renders, from the other end: a
    -- crate that CLIPS is a crate that grew. What a test can prove is that every
    -- part is asked for the size the config carries, and keeps being asked.
    clientReset()
    announce()
    render()

    local crate = entsOfModel(A.crateProp)[1]
    local chute = entsOfModel(A.chuteModel)[1]
    -- THE CRATE IS AT AUTHORED SIZE NOW, and `scaled` is written by a stub that
    -- mirrors the real BR.Native.propScale: 1.0 is not a scale, it is the
    -- absence of one, and neither the stub nor the native writes a matrix for
    -- it. So the assertion is that NOTHING was applied -- which is the whole of
    -- the fix, because a matrix scale is exactly what cannot be applied to a
    -- box resting on the ground without burying half of it.
    eq(A.crateScale, 1.0, 'the crate is at authored size')
    eq(scaled[crate], nil, 'so no matrix scale is written to it at all')
    eq(scaled[chute], A.chuteScale, 'the canopy at chuteScale')

    -- The flare props only exist on the object route now, so the scale is
    -- asserted there rather than here. A fired flare is drawn at whatever size
    -- the engine draws a flare, and there is no lever on it at all.
    do
        clientReset()
        A.flareRoute = 'object'
        announce()
        render()
        local built = entsOfModel(flareProp())
        eq(#built, 2, 'the object route builds two flare props')
        for _, f in ipairs(built) do
            eq(scaled[f], A.flareScale, 'and each at flareScale')
        end
        clientReset()
        announce()
        render()
        crate = entsOfModel(A.crateProp)[1]
        chute = entsOfModel(A.chuteModel)[1]
    end

    -- ═══ AND AGAIN AFTER EVERY HEADING WRITE, WHICH IS THE HALF THAT MATTERS
    --     ═══
    --
    -- SetEntityHeading is a matrix write and a matrix write resets the axis
    -- vectors to unit length -- which is where the scale lives. place() writes
    -- a heading every frame, so a scale applied only at spawn is a crate that
    -- is 2x for one frame and authored size for the other 1800 of the descent.
    scaled = {}
    gameMs = gameMs + 5000
    render()
    eq(scaled[chute], A.chuteScale, 'the canopy is re-scaled after the frame\'s '
        .. 'heading write')

    -- ═══ THE FOUR NUMBERS, PINNED, BECAUSE THREE OF THEM ARE A REVERSAL ═══
    --
    -- The crate and its husk went back to authored size on 2026-08-23 and the
    -- canopy did not, and that split is the whole finding: a matrix scale grows
    -- a model about its ORIGIN, so it is free for a frozen collision-off canopy
    -- hanging in open air and it is a clip for a dynamic physics box whose
    -- height comes from resting on the ground with a 1x collider. It cannot be
    -- offset away either -- gravity puts a dynamic object back on that collider
    -- on the next step. See the PROP SIZE block in br_lib/config/airdrop.lua.
    eq(A.crateScale, 1.0, 'the crate is at authored size, because a scaled one '
        .. 'draws its bottom half underneath the floor it stands on')
    eq(A.huskScale, 1.0, 'the husk matches it, so the box does not change size '
        .. 'when it is opened')
    eq(A.chuteScale, 2.5, 'and the canopy keeps its 2.5, which the owner asked '
        .. 'for by name')
    -- FOUR, AND THE FOURTH IS ALSO A REVERSAL NOW. The pile was asked for at 5x
    -- on 2026-08-22 and cut to 3x on 2026-09-01 -- "The volts prop is still
    -- about 40% too big", and 5.0 x 0.6 = 3.0. It is pinned here for the same
    -- reason the three above are: the number is the whole fix, and a silent
    -- drift back is the failure this assertion exists to catch.
    eq(A.voltsScale, 3.0, 'the Volts pile is three times, his 40% off the five')
end

describe('client: a sited drop is a blip and NOTHING ELSE')
do
    -- ═══ THE STATE EVERY DROP NOW STARTS IN ═══
    --
    -- Owner, 2026-08-22: "the drop should never happen until a player is within
    -- 200m of the drop location. That way they get to see the drop happen."
    --
    -- The server sites and ANNOUNCES at schedule time -- otherwise the gate is
    -- circular, because nobody can walk towards a drop they have not been told
    -- about -- and holds the descent. So the first record a client ever sees has
    -- a tStart and no landing time, and everything it draws except the blip must
    -- stay switched off.
    clientReset()
    local rec = announceSited()

    ok(not BR.AirdropArmed(rec), 'the record is not armed')
    ok(oneBlip() ~= nil, 'the blip is up the moment it is announced')

    -- Wind well past where the crate WOULD have been released and landed, had
    -- this been an old-style record. Nothing may appear.
    for _ = 1, 5 do
        gameMs = gameMs + A.planeLeadMs + A.descentMs
        render()
    end
    eq(onePlane(), nil, 'no aircraft, however long it waits')
    eq(onePed(), nil, 'and no pilot')
    eq(entCount(), 0, 'and no crate, no canopy and no flares')
    ok(oneBlip() ~= nil, 'but the blip is still there, doing its job')

    -- ═══ AND THE MOMENT THE SERVER ARMS IT, EVERYTHING STARTS ═══
    --
    -- The same record, mutated and re-sent. The client's handler has always
    -- treated a re-send as a replacement, which is the whole mechanism.
    armSited(rec)
    ok(BR.AirdropArmed(rec), 'the re-sent record is armed')
    render()
    ok(onePlane() ~= nil, 'and the aircraft is built')

    gameMs = gameMs + A.planeLeadMs
    render()
    ok(entCount() > 0, 'and the crate is released on the new clock')
end

describe('client: an unarmed record answers no to every descent question')
do
    -- The predicates guard themselves rather than relying on the render loop to
    -- guard them, because they are read from the diagnostic command and the
    -- server tick as well. Before the gate, tLand was always present and
    -- `(rec.tLand or 0.0)` would have read a missing one as zero -- reporting a
    -- waiting drop as fully descended, which is the wrong end of the fall.
    local sited = BR.BuildAirdropSite(1,
        { id = 'x', x = 0.0, y = 0.0, z = 0.0 }, 260.0, 1000.0, 0.0)

    ok(not BR.AirdropArmed(sited), 'it is not armed')
    ok(not BR.AirdropArmed(nil), 'and neither is nothing')
    ok(not BR.AirdropReleased(sited, 1e9), 'nothing is released from it, ever')
    ok(not BR.AirdropLanded(sited, 1e9), 'it never lands')
    ok(not BR.AirdropPlaneVisible(sited, 1e9, A), 'no aircraft is ever visible')
    ok(near(BR.AirdropProgress(sited, 1e9), 0.0),
        'and it is at the START of the fall, not the end',
        ('%.3f'):format(BR.AirdropProgress(sited, 1e9)))
    ok(near(BR.AirdropHeightAt(sited, 1e9), 260.0),
        'so it is still at full altitude, aboard an aircraft that has not flown')

    -- THE BLIP IS THE ONE THING THAT DOES WORK, and its ceiling is the deadline
    -- for somebody to turn up -- the server abandons the drop at exactly the
    -- instant this goes false, so the two cannot disagree.
    ok(BR.AirdropBlipVisible(sited, 1000.0, A), 'the blip is up at tStart')
    eq(BR.AirdropBlipEndsAt(sited, A), 1000.0 + A.blipMaxMs,
        'and runs the full ceiling from the announcement')

    -- ...AND ARMING RESTARTS THAT CEILING, which it has to: a drop that waited
    -- three minutes would otherwise have its blip expire twelve seconds after
    -- the crate touched down -- and the client's teardown fires on the same
    -- boundary, so the whole drop would be destroyed mid-descent.
    local armed = BR.BuildAirdropSite(1,
        { id = 'x', x = 0.0, y = 0.0, z = 0.0 }, 260.0, 1000.0, 0.0)
    BR.ArmAirdropRecord(armed, 181000.0, A)   -- three minutes of waiting
    eq(armed.tArm, 181000.0, 'the arm is stamped')
    eq(armed.tRelease, 181000.0 + A.planeLeadMs, 'the release follows it')
    -- THE LANDING IS SOLVED FROM THE RECORD'S OWN ALTITUDE (2026-08-28). This
    -- record carries 260 rather than the config's 225, and the fall curve is a
    -- fraction of whatever altitude it is given -- so the stretch this drop gets
    -- is its own and the assertion has to ask for it that way.
    ok(near(armed.tLand,
            181000.0 + A.planeLeadMs + BR.AirdropFallMs(A, armed.alt), 1e-6),
        'and the landing', ('%s'):format(tostring(armed.tLand)))
    eq(BR.AirdropBlipEndsAt(armed, A), 181000.0 + A.blipMaxMs,
        'and the ceiling now runs from the ARM, not from the announcement')
    ok(not BR.AirdropExpired(armed, armed.tLand, A),
        'so the drop is emphatically not torn down while the crate is landing')

    -- ═══ AND NO AIRCRAFT EXISTS DURING THE WAIT, EVEN THOUGH THE RECORD IS NOW
    --     ARMED ═══
    --
    -- The plane's window used to open at tStart. With a three-minute wait
    -- between the announcement and the arm, measuring from tStart would put a
    -- Titan over the drop point for the whole wait -- the empty-sky flyover the
    -- gate was added to stop, wearing the gate's own record.
    ok(not BR.AirdropPlaneVisible(armed, 1000.0, A),
        'no aircraft at the announcement...')
    ok(not BR.AirdropPlaneVisible(armed, 180999.0, A),
        '...nor a millisecond before the arm')
    ok(BR.AirdropPlaneVisible(armed, 181000.0, A),
        'and one exactly at it')
end

describe('client: a rooftop crate lands ON the roof, not through it')
do
    -- ═══ THE REVERSAL, AND THE OWNER SAW IT IN ONE MATCH ═══
    --
    -- Owner, 2026-08-22: "Somehow these airdrops can happen on top of buildings
    -- where peds otherwise cannot access." The answer written that day was to
    -- take the POI's authored street-level z whenever the navmesh refused the
    -- probed surface, and to draw the crate falling to THAT.
    --
    -- Owner, 2026-08-23, having played it: "when it lands on top of a building
    -- the loot crate falls through the top of the building as if it doesn't
    -- have collisions. This leads to (when the chute is removed) the actual
    -- crate prop spawning at ground level inside a building."
    --
    -- IT DOES NOT HAVE COLLISION -- makePart switches it off on purpose -- so
    -- aiming it below the surface it is over does not land it there, it sinks it
    -- through the roof in full view. A crate on a roof needs a way up. A crate
    -- inside a sealed building is loot nobody can ever have.
    --
    -- So the probed surface is used, roof or not, and the reachability verdict
    -- is kept as a DIAGNOSTIC. What relocates unreachable loot is
    -- client/loot.lua's repair round-trip, which moves an entry LATERALLY under
    -- the server's own 30m bound -- the only shape of correction that cannot
    -- bury a crate.
    clientReset()
    ground.z = 84.0              -- a roof, 54m above the POI's authored 30m
    reachable, reachWhy = false, 'snapped 54.0m in z'
    local rec = announce()
    render()
    local crate = oneEnt()
    ok(crate ~= nil, 'the crate exists')
    -- ═══ READ AT TOUCHDOWN, NOT AT THE RELEASE (2026-08-23) ═══
    --
    -- The release height is the AUTHORED one now, because that is where the
    -- aircraft is; the probe's answer is the LANDING height. So the question
    -- this block has always asked -- "does it come down on the roof or on the
    -- street inside the building" -- is a question about the far end of the
    -- fall, and it is read one frame before tLand, where the crate still exists.
    ok(near(crate.z, rec.gz + rec.alt, 0.001),
        'it leaves from the authored height, under the aircraft',
        ('%.1f'):format(crate.z))
    gameMs = gameMs + A.descentMs - 1
    render()
    local landing = crateMove()
    ok(landing and near(landing.z, 84.0, 0.05),
        'and it is falling to the ROOF the probe found, not to the authored '
        .. 'street below it',
        landing and ('%.1f, roof %.1f, authored %.1f')
            :format(landing.z, 84.0, rec.gz))
    ok(landing and not near(landing.z, rec.gz, 1.0),
        'which is the height that used to sink it into the building')

    -- AND THE VERDICT IS STILL TAKEN, because /brairdrop prints it and "it came
    -- down on the Maze Bank" has to be legible from a log. It just no longer
    -- moves anything.
    local printed = {}
    local realPrintFn = print
    print = function(s) printed[#printed + 1] = tostring(s) end
    commands['brairdrop'](0, {}, '')
    print = realPrintFn
    local joined = table.concat(printed, '\n')
    ok(joined:find('unreachable', 1, true) ~= nil
       and joined:find('snapped 54.0m in z', 1, true) ~= nil,
        'and the rooftop verdict is still reported by /brairdrop')

    -- AND WHEN THE NAVMESH IS HAPPY, NOTHING CHANGES AT ALL. Same height, same
    -- probe, no verdict -- which is the case that proves the two paths have
    -- converged rather than merely both existing.
    clientReset()
    ground.z = 84.0
    reachable, reachWhy = true, 'ok'
    announce()
    render()
    gameMs = gameMs + A.descentMs - 1
    render()
    local crate2 = crateMove()
    ok(crate2 ~= nil and near(crate2.z, 84.0, 0.05),
        'a reachable probe is used as-is',
        crate2 and ('%.1f'):format(crate2.z) or 'no crate')
end

-- ----------------------------------------------------------------- result ---

print = realPrint

io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
