-- Unit tests for the four permanent warmup crates (owner, 2026-09-04).
--
-- TWO HALVES, AND BOTH LOAD THE REAL FILES.
--
--   PART A is the pure side: br_lib/config/warmupcrates.lua. The owner's four
--   coordinates and his rarity ladder are pinned as LITERALS -- they are the one
--   thing in this feature nobody may adjust, and a test that read them out of
--   the config would agree with any edit -- and the contents roll is swept
--   across every rarity and thousands of seeds, because "a crate that displays
--   the rarity it was authored with" is a claim about a distribution rather than
--   about one draw.
--
--   PART B loads br_core/server/warmupcrates.lua itself against a stubbed
--   scheduler and a faithful miniature of the loot registry, and drives the
--   whole cycle by hand: place, open, stand next to it, walk away, watch the
--   spill go home, watch it reseal -- twice, because "infinitely" is a claim
--   about the SECOND cycle and every one after it, not the first.
--
-- WHAT THIS CANNOT TELL YOU. There is no FiveM here. Whether a prop actually
-- stays put when a car hits it, whether GetClosestObjectOfType finds the crate
-- on this build, and whether the loot visibly flies home are questions only a
-- playtest answers -- br_core/client/warmupcrates.lua is not loaded here and
-- says so in its own header.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_warmupcrates.lua

local realPrint = print
local realExit  = os.exit

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
    'br_lib/shared/polygon.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    -- The subject. AFTER config/loot.lua and config/weapons.lua, exactly as
    -- br_core's manifest orders it: it reads their rarity buckets and the two
    -- crate prop names, though at call time rather than at load.
    'br_lib/config/warmupcrates.lua',
    'br_lib/shared/loot_gen.lua',
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

local W = BR.Config.WarmupCrates
local R = BR.Rarity

-- =========================================================================
-- PART A -- the authored numbers and the roll
-- =========================================================================

describe('anchors: the owner\'s surveyed coordinates')
do
    eq(#W.anchors, 4, 'there are four of them')

    -- ═══ VERBATIM, AND THAT IS THE ENTIRE POINT OF THIS BLOCK ═══
    --
    -- Owner, 2026-09-04, in the order he wrote them:
    --   1. 4523.67, -4453.56, 4.77   heading 334.5
    --   2. 4526.88, -4459.69, 4.36   heading 292.1
    --   3. 4528.40, -4464.43, 4.45   heading 291.4
    --   4. 4532.05, -4471.95, 4.27   heading 290.7
    --
    -- He has said of other placements, of this same island: "No those coords are
    -- very specifically placed. Don't change them." A rounded z or a ground
    -- probe would move a crate by centimetres, look fine in a screenshot, and be
    -- exactly the thing he asked for twice not to happen -- so the numbers are
    -- written out again here rather than read back out of the table under test.
    local surveyed = {
        { x = 4523.67, y = -4453.56, z = 4.77, heading = 334.5 },
        { x = 4526.88, y = -4459.69, z = 4.36, heading = 292.1 },
        { x = 4528.40, y = -4464.43, z = 4.45, heading = 291.4 },
        { x = 4532.05, y = -4471.95, z = 4.27, heading = 290.7 },
    }
    for i, s in ipairs(surveyed) do
        local a = W.anchors[i] or {}
        eq(a.x, s.x, ('anchor %d x is the surveyed number'):format(i))
        eq(a.y, s.y, ('anchor %d y is the surveyed number'):format(i))
        eq(a.z, s.z, ('anchor %d z is the surveyed number'):format(i))
        eq(a.heading, s.heading, ('anchor %d heading is the surveyed number'):format(i))
    end

    -- ON THE ISLAND, not somewhere a typo would have put them. The warmup layout
    -- is sited in a disc around BR.Config.Match.warmupPos, and an anchor outside
    -- it is a crate no warmup player will ever be subscribed to.
    local pad = BR.Config.Match.warmupPos
    local far = 0.0
    for _, a in ipairs(W.anchors) do
        far = math.max(far, BR.Dist(a.x, a.y, pad.x, pad.y))
    end
    ok(far <= (BR.Config.Loot.warmup.radius or 460.0),
        'every anchor is inside the warmup island', ('furthest %.1fm'):format(far))
end

describe('the ladder')
do
    eq(W.anchors[1].rarity, R.COMMON, 'the first crate is common, as asked')
    eq(W.anchors[4].rarity, R.LEGENDARY, 'and the last is legendary')

    -- "Everything in between will increase in rarity until #4." STRICTLY
    -- increasing rather than non-decreasing: two crates side by side wearing the
    -- same colour is the one shape the sentence rules out.
    local rising = true
    for i = 2, #W.anchors do
        if W.anchors[i].rarity <= W.anchors[i - 1].rarity then rising = false end
    end
    ok(rising, 'and every step between them goes up')

    -- Four crates over five rarities means exactly one tier is unrepresented.
    -- Which one is a decision, not an accident, so it is worth a failing test if
    -- somebody quietly duplicates a tier instead of choosing.
    local seen = {}
    for _, a in ipairs(W.anchors) do seen[a.rarity] = (seen[a.rarity] or 0) + 1 end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    eq(distinct, 4, 'four crates wear four different rarities')
end

describe('contents: the authored rarity is what the crate displays')
do
    -- ONE CRATE'S WORTH IS NOT EVIDENCE. The guarantee is that EVERY roll, at
    -- every rarity, comes out at exactly the authored tier -- the ceiling is the
    -- common crate's problem and the floor is the legendary crate's, and a
    -- hundred draws would exercise neither reliably.
    local bad = nil
    for _, rarity in ipairs({ R.COMMON, R.UNCOMMON, R.RARE, R.EPIC, R.LEGENDARY }) do
        for seed = 1, 2000 do
            local c = BR.WarmupCrateContents(BR.Rng(seed * 31 + rarity), rarity)
            if BR.LootContentsRarity(c) ~= rarity then
                bad = bad or ('rarity %d seed %d gave %d')
                    :format(rarity, seed, BR.LootContentsRarity(c))
            end
            if #c ~= (W.items or 3) then
                bad = bad or ('rarity %d seed %d gave %d items'):format(rarity, seed, #c)
            end
        end
    end
    ok(bad == nil, '10,000 crates across all five rarities display exactly theirs', bad)

    -- NOTHING INSIDE MAY EXCEED THE CEILING EITHER, which is a stronger claim
    -- than the maximum matching: a common crate holding one legendary rifle and
    -- one legendary shield would fail the line above, but a bug that only
    -- overshot on the SUPPORTING items would slip past a test that looked at the
    -- headline slot alone.
    local over = nil
    for seed = 1, 2000 do
        for _, s in ipairs(BR.WarmupCrateContents(BR.Rng(seed), R.COMMON)) do
            if (s.rarity or 1) > R.COMMON then
                over = over or ('%s is rarity %d'):format(tostring(s.item), s.rarity)
            end
        end
    end
    ok(over == nil, 'and the common crate holds nothing above common', over)

    -- Every stack has to be something the inventory can actually take: an item
    -- id, a kind and a count. A nil id is the failure mode BR.LootPickOfRarity's
    -- walk exists to prevent, and it would land here first.
    local malformed = nil
    for seed = 1, 500 do
        for _, s in ipairs(BR.WarmupCrateContents(BR.Rng(seed), R.LEGENDARY)) do
            if type(s.item) ~= 'string' or not s.kind or (s.count or 0) < 1 then
                malformed = malformed or ('seed %d: %s'):format(seed, tostring(s.item))
            end
        end
    end
    ok(malformed == nil, 'and every stack is a real item with a kind and a count',
       malformed)
end

describe('the stack: shaped like every other crate')
do
    local a = W.anchors[4]
    local s = BR.WarmupCrateStack(BR.Rng(7), a)

    eq(s.kind, 'chest', 'it is a chest')
    eq(s.item, 'chest', 'and it calls itself one, so it looks like one')
    eq(s.prop, BR.Config.Loot.chestProp, 'wearing the sealed crate model')
    eq(s.rarity, a.rarity, 'displaying the rarity the anchor authored')
    eq(s.heading, a.heading, 'at the surveyed heading, not a random one')
    eq(s.x, a.x, 'at the surveyed x')
    eq(s.y, a.y, 'and y')
    eq(s.z, a.z, 'and the surveyed z, unrounded and unprobed')

    -- ═══ THE FLAG THAT MUST NOT BE THERE ═══
    --
    -- `warmup = true` means "when this is opened, queue a replacement somewhere
    -- else on the island" -- br_core/server/loot.lua's claim handler feeds
    -- BR.Config.Loot.warmup.respawnMs off it. On one of these four it would
    -- breed a fifth crate at a random point every time anybody opened it,
    -- forever, on top of the reset this feature already does.
    ok(s.warmup == nil, 'and it does NOT ask the island to respawn it elsewhere')

    -- A crate that rolled its own heading would be indistinguishable from one
    -- that was placed, until you looked at two of them.
    local headings = {}
    for seed = 1, 50 do
        headings[BR.WarmupCrateStack(BR.Rng(seed), a).heading] = true
    end
    local n = 0
    for _ in pairs(headings) do n = n + 1 end
    eq(n, 1, 'and fifty rolls of it all face the same way')
end

-- =========================================================================
-- PART B -- the server
-- =========================================================================

-- Stubs. Everything br_core/server/warmupcrates.lua reaches for, and nothing
-- else. BR.Rng, BR.Dist, BR.LootContentsRarity and the whole of
-- config/warmupcrates.lua are the REAL ones -- a stub of any of those would make
-- this suite agree with itself rather than with the code.

local jobs     = {}   -- [name] = fn, so the tick can be stepped by hand
local commands = {}   -- [name] = fn
local sent     = {}   -- every TriggerClientEvent
local logs     = {}

function print(s) logs[#logs + 1] = tostring(s) end

BR.Sched = { every = function(_, name, fn) jobs[name] = fn end }

function RegisterCommand(name, fn) commands[name] = fn end

function TriggerClientEvent(event, src, payload)
    sent[#sent + 1] = { event = event, src = src, payload = payload }
end

--- A miniature of the shared warmup zone.
---
--- FAITHFUL WHERE IT MATTERS AND TINY EVERYWHERE ELSE. It carries the two things
--- the file under test actually reads -- `loot.items` keyed by id, and entries
--- carrying the `fx`/`fy` origin BR.Loot.spawnStack stamps on anything born from
--- a container -- and nothing else. Cells and subscriptions are not modelled
--- because this file never touches them: the return message goes to warmup
--- players rather than to cell subscribers, deliberately, and the note in
--- beginReset says why.
local zone = { id = 0, warmup = true, loot = { items = {}, nextId = 0 } }

BR.Loot = {
    warmupZone = function() return zone end,
    spawnStack = function(m, stack, x, y, z, from)
        m.loot.nextId = m.loot.nextId + 1
        local e = {
            id = m.loot.nextId,
            item = stack.item, kind = stack.kind, rarity = stack.rarity,
            count = stack.count or 1, clip = stack.clip,
            x = x, y = y, z = z,
            prop = stack.prop, heading = stack.heading,
            contents = stack.contents, warmup = stack.warmup,
            fx = from and from.x or nil,
            fy = from and from.y or nil,
        }
        m.loot.items[e.id] = e
        return e
    end,
    remove = function(m, e) m.loot.items[e.id] = nil end,
    reannounce = function(m, e)
        sent[#sent + 1] = { event = 'reannounce', id = e.id, kind = e.kind }
    end,
}

local roster = {}
BR.Roster = {
    each = function(pred, fn)
        for src, e in pairs(roster) do
            if not pred or pred(e) then fn(src, e) end
        end
    end,
}

--- Stand a warmup player `dist` metres east of a point.
local function standAt(src, x, y, dist)
    roster[src] = {
        state = BR.PlayerState.WARMUP,
        pos = { x = x + dist, y = y, z = 0.0 },
    }
end

local function clearRoster() roster = {} end

loadAll({ 'br_core/server/warmupcrates.lua' })

local tick = jobs['warmupcrates.tick']

--- Run the tick after advancing the clock.
local function step(ms)
    gameMs = gameMs + (ms or 250)
    tick()
end

--- The four live entries, in anchor order. Read out of the registry rather than
--- out of the file's own state, so a test cannot be satisfied by bookkeeping
--- that never reached the world.
local function entriesAt()
    local out = {}
    for i, a in ipairs(W.anchors) do
        for _, e in pairs(zone.loot.items) do
            if e.x == a.x and e.y == a.y and (e.kind == 'chest' or e.kind == 'husk') then
                out[i] = e
            end
        end
    end
    return out
end

--- Open a crate the way br_core/server/loot.lua's claim handler does.
---
--- THIS FIXTURE IS A COPY OF scatter() + toHusk() AND HAS TO STAY ONE. Those two
--- are what the reset undoes -- reseal() in the file under test is written as
--- toHusk's mirror field for field -- so if either grows a field, this and that
--- both have to learn it. Quoted here rather than called because the real ones
--- are locals inside a 1700-line file that needs half the server to load.
local function openCrate(e)
    local contents = e.contents or {}
    for i, s in ipairs(contents) do
        -- The spill: contents land AROUND the container, carrying its position
        -- as their origin. `spill()` deals a ring; the angle does not matter
        -- here, only that the items are near the crate and stamped with it.
        BR.Loot.spawnStack(zone, s,
            e.x + 0.4 * i, e.y + 0.3 * i, e.z,
            { x = e.x, y = e.y, lift = 0.6 })
    end
    e.kind, e.item = 'husk', 'husk'
    e.prop = BR.Config.Loot.chestOpenProp
    e.rarity = BR.Rarity.COMMON
    e.contents = nil
end

--- How many entries in the registry were spilled by this crate.
local function spillCount(a)
    local n = 0
    for _, e in pairs(zone.loot.items) do
        if e.fx == a.x and e.fy == a.y then n = n + 1 end
    end
    return n
end

describe('placement')
do
    step()   -- the first tick places
    local es = entriesAt()

    eq(#es, 4, 'four crates are on the island')
    local placedRight = true
    for i, a in ipairs(W.anchors) do
        local e = es[i]
        if not e or e.x ~= a.x or e.y ~= a.y or e.z ~= a.z
           or e.heading ~= a.heading or e.kind ~= 'chest' then
            placedRight = false
        end
        if e and e.rarity ~= a.rarity then placedRight = false end
        -- See the PART A note: this flag would breed a fifth crate per open.
        if e and e.warmup then placedRight = false end
    end
    ok(placedRight,
       'each one is sealed, on its surveyed point, at its authored rarity, and unflagged')

    -- IDEMPOTENT. The tick runs four times a second forever; a placement pass
    -- that ran twice would double the island.
    for _ = 1, 8 do step() end
    eq(#entriesAt(), 4, 'and eighty ticks later there are still four')
end

describe('the cycle')
do
    local a  = W.anchors[3]
    local e  = entriesAt()[3]
    local id = e.id

    openCrate(e)
    eq(e.kind, 'husk', 'an opened crate is a husk')
    eq(spillCount(a), W.items or 3, 'and its contents are on the ground')

    -- ═══ SOMEBODY IS STANDING THERE ═══
    --
    -- The settle must not run while the player who opened it is still picking
    -- things up. Held open for well past settleMs, which is the case that would
    -- eat loot out from under them.
    standAt(1, a.x, a.y, 5.0)
    for _ = 1, 40 do step() end   -- 10 seconds, twice the settle
    eq(entriesAt()[3].kind, 'husk', 'a player within reach holds it open')
    eq(spillCount(a), W.items or 3, 'and nothing of theirs is taken away')

    -- Just outside pickup range is still standing there: `leaveRadius` is much
    -- wider than the 3.5m reach on purpose.
    standAt(1, a.x, a.y, (W.leaveRadius or 22.0) - 2.0)
    for _ = 1, 40 do step() end
    eq(entriesAt()[3].kind, 'husk', 'and so is standing just inside leaveRadius')

    -- ═══ AND NOW THEY WALK AWAY ═══
    standAt(1, a.x, a.y, (W.leaveRadius or 22.0) + 5.0)

    -- Not instantly: settleMs is the difference between "stepped back" and
    -- "left".
    step()
    eq(entriesAt()[3].kind, 'husk', 'one tick after leaving it is still open')
    eq(spillCount(a), W.items or 3, 'and the spill is still there')

    -- Where the spill is standing, read out of the registry before the reset
    -- takes it away, so the message can be checked against the world rather
    -- than against itself.
    local where = {}
    for _, s in pairs(zone.loot.items) do
        if s.fx == a.x and s.fy == a.y then
            where[('%.4f,%.4f'):format(s.x, s.y)] = true
        end
    end

    local before = #sent
    for _ = 1, math.ceil((W.settleMs or 5000) / 250) + 1 do step() end

    eq(spillCount(a), 0, 'once the settle expires the spill is retired')
    local ret = nil
    for i = before + 1, #sent do
        if sent[i].event == BR.Net.WARMUP_CRATE_RETURN then ret = sent[i] end
    end
    ok(ret ~= nil, 'and the clients are told to fly it home')
    if ret then
        eq(#ret.payload.items, W.items or 3, 'every item is named in the message')
        eq(ret.payload.x, a.x, 'flying to the crate\'s x')
        eq(ret.payload.y, a.y, 'and its y')
        eq(ret.src, 1, 'and it went to the player on the island')

        -- ═══ POSITION AND NOTHING ELSE ═══
        --
        -- The client identifies each prop by looking at that point and reads the
        -- MODEL off whatever is standing there -- see propsAt() in
        -- br_core/client/warmupcrates.lua. A `prop` field here would be nil on
        -- almost every spilled item anyway (BR.RollLootStack returns an id, a
        -- kind and a count, never a model name), so a reader who added one back
        -- would be sending nils and would not find out.
        local shaped = true
        for _, it in ipairs(ret.payload.items) do
            if it.prop ~= nil or it.item ~= nil then shaped = false end
            if not where[('%.4f,%.4f'):format(it.x, it.y)] then shaped = false end
        end
        ok(shaped, 'and every entry in it is a position of a real spilled item')
    end

    -- ═══ THE RESEAL ═══
    --
    -- It does NOT happen in the same tick as the retirement: the loot has to
    -- reach the box before the box closes.
    eq(entriesAt()[3].kind, 'husk', 'the crate is still a husk while loot is in flight')

    for _ = 1, math.ceil((W.returnMs or 520) / 250) + 1 do step() end

    local after = entriesAt()[3]
    eq(after.kind, 'chest', 'and then it is a sealed crate again')
    eq(after.item, 'chest', 'calling itself one')
    eq(after.prop, BR.Config.Loot.chestProp, 'wearing the sealed model')
    eq(after.rarity, a.rarity, 'at the rarity the owner authored, not a rolled one')
    eq(after.heading, a.heading, 'facing the way he placed it')
    eq(after.x, a.x, 'on its surveyed x')
    eq(after.z, a.z, 'and its surveyed z')
    eq(#(after.contents or {}), W.items or 3, 'holding a fresh set of contents')

    -- ═══ THE ID IS THE SAME ONE ═══
    --
    -- Same entry, mutated in place -- which is what makes the client swap one
    -- model for the other instead of deleting a box and streaming a new one, and
    -- what stops the id space growing by four every cycle for the life of the
    -- server.
    eq(after.id, id, 'and it is the same entry it always was')
end

describe('and again, and again')
do
    -- ═══ "CYCLED THROUGH OPEN/CLOSED STATES INFINITELY" ═══
    --
    -- The first cycle proves the code runs. The claim is about the hundredth, so
    -- this runs twenty and then asserts the two things that would drift if
    -- anything accumulated: the registry holds exactly the four crates plus
    -- whatever is currently spilled, and the entry ids never moved.
    local a = W.anchors[1]
    clearRoster()   -- nobody on the island at all: the reset must still happen

    local id = entriesAt()[1].id

    for _ = 1, 20 do
        openCrate(entriesAt()[1])
        for _ = 1, math.ceil(((W.settleMs or 5000) + (W.returnMs or 520)) / 250) + 2 do
            step()
        end
    end

    local e = entriesAt()[1]
    eq(e.kind, 'chest', 'twenty cycles later it is sealed')
    eq(e.id, id, 'still the same entry')
    eq(e.rarity, a.rarity, 'still common, as the owner asked')
    eq(e.x, a.x, 'still exactly where he put it')
    eq(e.z, a.z, 'at exactly the height he read off')

    local n = 0
    for _ in pairs(zone.loot.items) do n = n + 1 end
    eq(n, 4, 'and the registry holds four entries, not eighty-four')
end

describe('diagnostics')
do
    ok(commands['brwarmupcrates'] ~= nil, 'the state dump is registered')

    -- NO THIRD ARGUMENT. br_lib/shared/devgate.lua wraps RegisterCommand for the
    -- whole project; passing `restricted` would make this ace-gated instead,
    -- which FiveM's console refuses in production mode. The stub above takes two
    -- parameters, so a third would be silently dropped -- which is exactly why
    -- the state dump is also read below, rather than only counted.
    local before = #logs
    commands['brwarmupcrates']()
    ok(#logs > before + #W.anchors, 'and it prints a line per crate plus a header')

    local s = BR.WarmupCrates.state()
    eq(#s, 4, 'the state accessor answers for all four')
    eq(s[4].rarity, R.LEGENDARY, 'naming the legendary one')
    ok(s[1].cycles >= 20, 'and the cycle counter proves the loop is a loop',
       tostring(s[1].cycles))

    -- A COPY, NOT THE RECORD. The caller must not be able to stop a reset by
    -- writing to what it was handed.
    s[1].cycles = -1
    ok(BR.WarmupCrates.state()[1].cycles >= 20, 'and the caller got a copy')
end

-- ------------------------------------------------------------------ result ---

if fail == 0 then
    realPrint(('\27[32m%d passed\27[0m'):format(pass))
    realExit(0)
end
realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
realExit(1)
