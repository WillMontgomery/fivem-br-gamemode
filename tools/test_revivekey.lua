-- Unit tests for the squad's revive key (#219 step 4).
--
-- ═══ WHY THIS IS ITS OWN SUITE, AND WHAT IS DELIBERATELY NOT IN IT ═══
--
-- THE ONE RULE THIS FILE CANNOT ASSERT IS THE MOST IMPORTANT ONE. "The key is
-- minted on the same edge that spills the inventory" is a property of
-- server/combat.lua, not of server/revivekey.lua -- so it is asserted in
-- tools/test_roster.lua's `combat.revivekey`, where the real eliminate() runs
-- against the real roster, the real loot table and the real #144 hold. A
-- sandbox that called BR.ReviveKey.onEliminated by hand would be testing that
-- this file does what it is told, which is not the question.
--
-- WHAT IS HERE is everything downstream of the mint, and all of it is awkward to
-- reach from a live match: a three-minute expiry, a squadmate walking the last
-- 2.5 metres, a DynamoDB round trip that another elimination lands inside, and
-- two squadmates pressing buy in the same second. Every one of those is minutes
-- of a playtest and three lines here.
--
-- ═══ THE CASE THIS SUITE EXISTS FOR, IF YOU READ ONE ═══
--
-- THE SUBJECT MUST NOT COLLECT THEIR OWN KEY. An eliminated player's `pos` IS
-- the key's position -- they are spectating from the body it was minted at --
-- so the distance from the corpse to the key it left is zero, for ever. Get
-- this wrong and every key in the game collects itself on the tick after it is
-- minted, every squad silently holds every key for free, and a solo playtester
-- sees a feature that works perfectly. It is the one defect here that is
-- invisible from inside the game.
--
-- ⚠ TWO INDEPENDENT GUARDS STOP IT, AND EITHER ALONE IS SUFFICIENT -- the
-- collector filter admits only ALIVE, and the inner loop skips `mv.src == src`.
-- That is worth knowing before reading the assertion below, because it means
-- REMOVING EITHER ONE ON ITS OWN LEAVES THIS SUITE GREEN. Measured, not
-- assumed: both single-guard mutations were run and both stayed green; the
-- combined one goes red. So the assertion here pins the BEHAVIOUR and the
-- redundancy is the belt-and-braces, rather than the assertion pinning one
-- guard that somebody could then delete believing a test covers it.

local fakeTime = 0
function GetGameTimer() return fakeTime end

--- The module's console lines, captured rather than printed.
---
--- server/revivekey.lua narrates every mint, collection, expiry and purchase --
--- which is what a playtest log is for and is exactly wrong in a gate that runs
--- twenty-five suites. tools/test_roster.lua does the same thing for the same
--- reason; `realPrint` is what this file's own output goes through.
---
--- KEPT RATHER THAN DISCARDED, and bounded, so a failing assertion can still be
--- read against what the module said it was doing.
local realPrint = print
local PRINT_KEEP = 256
local printed = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
    if #printed > PRINT_KEEP then table.remove(printed, 1) end
end

local RES = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'
local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
--- A br_core module, by its path under resources/[fivem-royale]/.
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',        -- BR.Dist, which both the collect and reach tests use
    'shared/protocol.lua',   -- BR.Net, for the handler driven below
    'config/match.lua',
    'config/overrides.lua',
    'config/storm.lua',
    'config/map.lua',
    'config/loot.lua',
    'config/rescue.lua',     -- the `models` list config/revivekey.lua reads
    'config/revivekey.lua',
}) do load(f) end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local K = BR.Config.ReviveKey

-- ---------------------------------------------------------------------------
describe('config')
do
    -- THE OWNER'S TWO NUMBERS, 2026-08-30. Both supersede #219's body, which was
    -- written a week earlier and says 150 Volts and nothing about expiry -- so
    -- these are asserted against his message rather than against the issue.
    ok(K.expiryMs == 180000, 'the pickup lives three minutes', K.expiryMs)
    ok(K.price == 25, 'and a key costs 25 Volts, not the 150 in the issue body',
        K.price)
    ok(K.buysAll == true,
        'and one purchase covers all of the squad\'s outstanding keys')

    -- ONE LIST FOR "AMBULANCE", SHARED WITH THE OTHER TWO FEATURES. If somebody
    -- ever pastes a model name into config/revivekey.lua, this feature starts
    -- disagreeing with the rescue and the heal about what a player is standing
    -- next to -- and the symptom is a purchase refused at a van two other
    -- features are happy to use.
    ok(BR.Config.ReviveKey.models() == BR.Config.Rescue.models,
        'and "what counts as an ambulance" is config/rescue.lua\'s one list, '
            .. 'not a copy of it')

    -- ═══ NO STRINGS, AND THAT IS AN ASSERTION RATHER THAN AN OBSERVATION ═══
    --
    -- #219 Q20 -- what the squad is told and when -- is UNANSWERED, and the
    -- owner's standing rule is that copy he did not ask for reads as slop. This
    -- config must not grow a prompt, a toast or a marker label before he writes
    -- one; the failure mode is that somebody adds a "helpful" default and it
    -- ships as if it were his.
    for _, k in ipairs({ 'prompt', 'label', 'text', 'toast', 'notify',
                         'pickupText', 'boughtText' }) do
        ok(K[k] == nil,
            ('config/revivekey.lua has no `%s` -- the owner has given no '
                .. 'wording for this feature and none may be invented'):format(k))
    end

    -- ═══ AND NO RESURRECTION NUMBERS ═══
    --
    -- Step 5 is gated on four unanswered questions (Q10 storm, Q11 helper
    -- scaling, Q18 late game, Q21 what they return with). A number written here
    -- ahead of them would be a guess wearing the authority of config, and the
    -- next person would read it as a decision.
    for _, k in ipairs({ 'holdMs', 'dropHeightM', 'reviveHp', 'parachute',
                         'maxRevives' }) do
        ok(K[k] == nil,
            ('config/revivekey.lua has no `%s` -- resurrection is step 5 and '
                .. 'its numbers are not the owner\'s yet'):format(k))
    end
end

-- ---------------------------------------------------------------------------
describe('source')
do
    -- ═══ NO PLAYER-FACING COPY IN THE SERVER FILE EITHER ═══
    --
    -- The config assertions above stop a string being ADDED to the config; this
    -- stops one being written straight into the module. #219 Q20 is unanswered
    -- and the owner's rule is that copy he did not ask for reads as slop, so the
    -- only sentence this feature may speak is the market's own shortfall line --
    -- which BR.Market.charge speaks, inside the market, and which already
    -- existed for exactly this fact.
    --
    -- ═══ IT RUNS HERE, BEFORE THE MODULE IS LOADED, AND THAT IS DELIBERATE ═══
    --
    -- This suite's BR.Server stub has no `notify` -- so a notify call added to
    -- the module would THROW inside the buy callback three hundred lines below
    -- and take the whole suite down with a traceback instead of a named
    -- assertion. A crash is a red build, so the rule would still be enforced,
    -- but the report would say "attempt to call a nil value" rather than "there
    -- is no wording for this feature". Read before load, it fails as itself.
    local fh = io.open(RES .. 'br_core/server/revivekey.lua', 'r')
    ok(fh ~= nil, 'the server module is readable')
    local moduleSrc = fh and fh:read('a') or ''
    if fh then fh:close() end

    -- Strip comments, so the prose ABOUT notifying does not read as notifying.
    local code = moduleSrc:gsub('%-%-[^\n]*', '')

    for _, fn in ipairs({ 'BR%.Server%.notify', 'BR%.Server%.notifyClear' }) do
        ok(not code:find(fn),
            ('server/revivekey.lua does not call %s -- there is no wording for '
                .. 'this feature and none may be invented'):format(
                (fn:gsub('%%', ''))))
    end

    -- AND IT WRITES NO PLAYER STATE. A key is an entitlement; resurrection is
    -- step 5. A state write from here would reach client/natives.lua's
    -- invincibility latch, which is derived from the player state and nothing
    -- else.
    ok(not code:find('Roster%.setState'),
        'and it writes no player state -- nothing here resurrects anybody')
end

-- ---------------------------------------------------------------------------
-- The server module, with the world stubbed around it.
-- ---------------------------------------------------------------------------
local roster, matches, jobs, handlers = {}, {}, {}, {}
local charges, chargeAnswer

do
    -- MODEL 1 IS AN AMBULANCE AND NOTHING ELSE IS. Stubbed rather than borrowed
    -- from the real BR.Rescue, because what is under test is that
    -- server/revivekey.lua ASKS -- see `buy.refuse.notambulance`.
    local world = {
        [201] = { model = 1, x = 0.0,   y = 0.0   },   -- an ambulance
        [202] = { model = 2, x = 0.0,   y = 0.0   },   -- a car at the same spot
        [203] = { model = 1, x = 900.0, y = 900.0 },   -- an ambulance far away
    }
    local entOf = { [9201] = 201, [9202] = 202, [9203] = 203 }
    local gone  = {}

    -- ═══ DECLARED BEFORE loadCore, AND THAT ORDER IS LOAD-BEARING ═══
    --
    -- server/revivekey.lua resolves `can.entityFromNet` ONCE at load, the way
    -- server/ambheal.lua does. A stub installed afterwards would leave the
    -- module believing the native is missing, every purchase would be refused
    -- with 'no net id resolver on this build', and the whole buy section would
    -- pass its refusal tests for entirely the wrong reason.
    _G.NetworkGetEntityFromNetworkId = function(n) return entOf[n] end

    -- ═══ 1 AND 0, NOT true AND false, AND THAT IS THE POINT OF THE STUB ═══
    --
    -- DoesEntityExist is declared BOOL and a FiveM native declared BOOL hands
    -- Lua a NUMBER on some builds. `0` is truthy in Lua, so `if
    -- DoesEntityExist(e)` is true for an entity that does not exist -- ten
    -- shipped instances of that in this project, and tools/check_bool_natives.lua
    -- exists because of them.
    --
    -- A STUB THAT ANSWERED `false` WOULD HIDE THE BUG IT IS HERE TO CATCH: the
    -- refusal would pass with or without the isTrue() wrapper, and the suite
    -- would go green on a build where a destroyed ambulance still sells revive
    -- keys. Answering 1/0 makes the wrapper load-bearing here rather than in a
    -- playtest.
    _G.DoesEntityExist = function(e)
        return (world[e] ~= nil and not gone[e]) and 1 or 0
    end
    _G.GetEntityModel  = function(e) return (world[e] or {}).model end
    _G.GetEntityCoords = function(e)
        local v = world[e] or {}
        return { x = v.x or 0.0, y = v.y or 0.0, z = 0.0 }
    end

    _G.vanish = function(e) gone[e] = true end
    _G.unvanish = function(e) gone[e] = nil end

    BR.Rescue = { isAmbulance = function(m) return m == 1 end }

    BR.Roster = {
        get  = function(src) return roster[src] end,
        each = function(pred, fn)
            -- SORTED, because two of the tests below assert WHICH squadmate
            -- collected a key and pairs() order is not defined. A suite that
            -- passed on one Lua build and failed on the next would be worse
            -- than no suite.
            local ids = {}
            for src in pairs(roster) do ids[#ids + 1] = src end
            table.sort(ids)
            for _, src in ipairs(ids) do
                local e = roster[src]
                if not pred or pred(e) then fn(src, e) end
            end
        end,
    }
    BR.Server = { matches = matches }
    BR.Sched  = { every = function(_, name, fn) jobs[name] = fn end }

    -- THE MARKET, DRIVEN RATHER THAN STUBBED OUT. `charge` answers through a
    -- callback because it is a DynamoDB round trip, and the interesting cases
    -- here are all about WHAT HAPPENS DURING IT -- so the answer is deferred
    -- until a test calls `settle`, exactly as the real one defers until the row
    -- replies.
    charges = {}
    BR.Market = {
        charge = function(src, amount, reason, done)
            charges[#charges + 1] = {
                src = src, amount = amount, reason = reason, done = done,
            }
        end,
    }

    _G.RegisterNetEvent   = function() end
    _G.RegisterCommand    = function() end
    _G.AddEventHandler    = function(name, fn) handlers[name] = fn end
    _G.TriggerClientEvent = function() end

    loadCore('br_core/server/revivekey.lua')
end

--- Answer the oldest outstanding charge.
local function settle(paid, why, left)
    local c = table.remove(charges, 1)
    if not c then return false end
    c.done(paid, why, left)
    return true
end

--- Put a player in the world.
local function put(src, opts)
    opts = opts or {}
    matches[1] = matches[1] or { id = 1, state = BR.MatchState.PLAYING }
    roster[src] = {
        src     = src,
        name    = opts.name or ('P' .. src),
        matchId = opts.matchId or 1,
        squadId = opts.squadId,
        state   = opts.state or BR.PlayerState.ALIVE,
        pos     = { x = opts.x or 0.0, y = opts.y or 0.0, z = 0.0 },
    }
    return roster[src]
end

local function wipe()
    for k in pairs(roster) do roster[k] = nil end
    for k in pairs(matches) do matches[k] = nil end
    for i = #charges, 1, -1 do charges[i] = nil end
end

local sweep = jobs['revivekey.sweep']

-- ---------------------------------------------------------------------------
describe('sweep.registered')
do
    ok(sweep ~= nil, 'the sweep registered itself on the scheduler')
end

-- ---------------------------------------------------------------------------
describe('mint')
do
    wipe()
    fakeTime = 100000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    -- A SOLO GETS NOTHING. `squadId` is the gate, not the mode -- the same field
    -- server/combat.lua's tellSquad reads one screen above the call site.
    put(1, { squadId = nil, x = 10.0, y = 10.0 })
    ok(BR.ReviveKey.onEliminated(m, 1) == nil,
        'a player with no squad gets no key -- there would be nobody to own it')
    ok(roster[1].reviveKey == nil, 'and nothing is written to their entry')

    -- WITH A SQUAD, AT THE BODY.
    put(2, { squadId = 'A', x = 50.0, y = 60.0 })
    local rec = BR.ReviveKey.onEliminated(m, 2)
    ok(rec ~= nil, 'a squad player leaves a key')
    ok(rec.x == 50.0 and rec.y == 60.0, 'where they fell',
        rec and ('(%.1f, %.1f)'):format(rec.x, rec.y))
    ok(rec.held == false, 'which nobody holds yet')
    ok(rec.expiresAt == fakeTime + 180000, 'on a three-minute clock',
        rec.expiresAt - fakeTime)

    -- ═══ THE POSITION IS COPIED, NOT REFERENCED ═══
    --
    -- `entry.pos` is overwritten IN PLACE by the roster's sampler four times a
    -- second. A key that held the table rather than the numbers would follow the
    -- corpse through every physics nudge a body takes -- and a body on a slope
    -- keeps moving -- so the pickup would drift away from the blip its squad is
    -- running at.
    roster[2].pos.x, roster[2].pos.y = 999.0, 999.0
    ok(rec.x == 50.0 and rec.y == 60.0,
        'and the pickup does not follow the corpse when the sampler moves it',
        ('(%.1f, %.1f)'):format(rec.x, rec.y))

    -- IDEMPOTENT. Not reachable through eliminate() -- `canDie` refuses a player
    -- who is already OUT -- but the function is public and a second mint that
    -- overwrote the first would teleport a pickup somebody was walking to.
    roster[2].pos.x, roster[2].pos.y = 700.0, 700.0
    local again = BR.ReviveKey.onEliminated(m, 2)
    ok(again == rec, 'a second mint returns the first record rather than a new one')
    ok(rec.x == 50.0, 'and does not move the pickup', rec.x)

    -- NO MATCH, NO KEY. combat.lua guards on `m` for the death box and this
    -- inherits the same guard; asserted so the two cannot drift apart.
    put(3, { squadId = 'A', x = 1.0, y = 1.0 })
    ok(BR.ReviveKey.onEliminated(nil, 3) == nil, 'no match, no key')

    -- NO POSITION SAMPLE, NO KEY. A key with no coordinates is a pickup nobody
    -- can walk to and a blip pointing at the origin.
    put(4, { squadId = 'A' })
    roster[4].pos = nil
    ok(BR.ReviveKey.onEliminated(m, 4) == nil,
        'and a player the sampler has never seen leaves none either')
end

-- ---------------------------------------------------------------------------
describe('sweep.collect')
do
    -- A SQUADMATE WALKS OVER IT.
    wipe()
    fakeTime = 200000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE SUBJECT DOES NOT COLLECT THEIR OWN KEY. READ THE HEADER
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- An OUT player's `pos` is the corpse they are spectating from, which is
    -- EXACTLY the position the key was minted at -- distance zero, for ever. If
    -- the collector filter ever admits OUT, every key in the game collects
    -- itself on the tick after it is minted, every squad silently holds every
    -- key for free, and a solo playtester would see a feature that works.
    sweep()
    ok(dead.reviveKey.held == false,
        'the eliminated player does not collect their own key by lying on it '
            .. '-- their corpse is at distance zero from it, for ever')

    -- AN ENEMY STANDING ON THE BODY IS NOT A COLLECTOR (#219 Q2 is unanswered
    -- for VISIBILITY, but ownership is settled: the key is "owned by the
    -- squad").
    put(2, { squadId = 'B', x = 0.5, y = 0.0 })
    sweep()
    ok(dead.reviveKey.held == false,
        'and neither does an enemy squad standing on top of it')

    -- ANOTHER MATCH IS NOT THE SAME SQUAD EITHER, even sharing a squad id --
    -- ids are match-namespaced, so this is belt and braces on a real invariant.
    put(3, { squadId = 'A', matchId = 2, x = 0.0, y = 0.0 })
    sweep()
    ok(dead.reviveKey.held == false,
        'nor a player in another match who happens to share the squad id')

    -- OUT OF REACH IS OUT OF REACH.
    local mate = put(4, { squadId = 'A', x = 8.0, y = 0.0 })
    sweep()
    ok(dead.reviveKey.held == false,
        'a squadmate across the road has not collected anything')

    -- A DOWNED SQUADMATE IS NOT FETCHING ANYTHING. They crawl at 0.55 m/s and
    -- are bleeding out; if they are on the body it is because they were shot
    -- there.
    mate.pos.x = 1.0
    mate.state = BR.PlayerState.DBNO
    sweep()
    ok(dead.reviveKey.held == false,
        'and a DBNO squadmate lying next to it has not fetched it')

    -- ON THEIR FEET, ON THE BODY. This is the whole feature.
    mate.state = BR.PlayerState.ALIVE
    sweep()
    ok(dead.reviveKey.held == true, 'a living squadmate who walks to the body '
        .. 'collects the key')
    ok(dead.reviveKey.via == 'fetched', 'and it is recorded as fetched',
        dead.reviveKey.via)
    ok(BR.ReviveKey.heldFor(1) == true,
        'which is what step 5 will ask through BR.ReviveKey.heldFor')

    -- THE BOUNDARY, BOTH SIDES OF IT. `collectM` is 2.5 and it is a real edge
    -- rather than a suggestion.
    wipe()
    matches[1] = m
    local d2 = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    BR.ReviveKey.onEliminated(m, 1)
    d2.state = BR.PlayerState.OUT
    local m2 = put(2, { squadId = 'A', x = 2.6, y = 0.0 })
    sweep()
    ok(d2.reviveKey.held == false, 'at 2.6m it is still on the ground')
    m2.pos.x = 2.4
    sweep()
    ok(d2.reviveKey.held == true, 'and at 2.4m it is not')
end

-- ---------------------------------------------------------------------------
describe('sweep.expiry')
do
    wipe()
    fakeTime = 300000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local rec = BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT

    fakeTime = fakeTime + 179000
    sweep()
    ok(rec.lapsed ~= true, 'at 2:59 the pickup is still there')

    fakeTime = fakeTime + 2000
    sweep()
    ok(rec.lapsed == true, 'at 3:01 it is gone')

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE PICKUP EXPIRES. THE KEY DOES NOT. THESE ARE TWO CLOCKS
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- "The pickup expires on a timer, let's say 3 minutes. They can STILL
    --  purchase the revive keys at an ambulance for 25 volts" -- one sentence,
    -- and reading it as one clock would delete the purchase path. A squad that
    -- misses the trip has lost the free option, not the player.
    ok(dead.reviveKey ~= nil,
        'and the RECORD survives -- "they can still purchase" is the other half '
            .. 'of the sentence that set the timer')
    ok(BR.ReviveKey.outstanding('A', 1) == 1,
        'so an expired pickup is still an outstanding key to buy',
        BR.ReviveKey.outstanding('A', 1))

    -- AND A LATE ARRIVAL CANNOT WALK IT UP. The pickup is gone; only Volts
    -- reach it now.
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    sweep()
    ok(dead.reviveKey.held == false,
        'a squadmate who arrives after the timer collects nothing')

    -- THE LOG FIRES ONCE, NOT EVERY SECOND FOR THE REST OF THE MATCH.
    local before = rec.lapsed
    sweep(); sweep()
    ok(before == true and rec.lapsed == true,
        'and the expiry is latched rather than re-announced on every tick')

    -- ═══ THE BOUNDARY, AND THAT THE TWO OUTCOMES ARE COMPLEMENTS ═══
    --
    -- `pickupLive` is `now < expiresAt` and the expiry is `now >= expiresAt`, so
    -- no tick can both collect and expire one key. That is worth asserting
    -- rather than reasoning about, because the failure it prevents -- a key lost
    -- to the race on the tick a mate reaches it -- would be unreproducible in a
    -- playtest and would read as the collect radius being unreliable.
    wipe()
    fakeTime = 800000
    local m2 = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m2
    local d = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local r = BR.ReviveKey.onEliminated(m2, 1)
    d.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    fakeTime = r.expiresAt - 1
    sweep()
    ok(d.reviveKey.held == true and r.lapsed ~= true,
        'one millisecond before the deadline the mate collects it, and it does '
            .. 'not also expire')

    wipe()
    matches[1] = m2
    local d2 = put(1, { squadId = 'A', x = 0.0, y = 0.0 })
    local r2 = BR.ReviveKey.onEliminated(m2, 1)
    d2.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    fakeTime = r2.expiresAt
    sweep()
    ok(d2.reviveKey.held == false and r2.lapsed == true,
        'and exactly on it the pickup expires instead -- the two outcomes are '
            .. 'complements, so neither can be lost to the other')
end

-- ---------------------------------------------------------------------------
describe('buy.refuse')
do
    wipe()
    fakeTime = 400000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 500.0, y = 500.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT

    -- The buyer, standing on the ambulance at the origin.
    local buyer = put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    local function why(src, netId)
        local _, w = BR.ReviveKey.canBuy(src, roster[src], netId)
        return w
    end

    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'the ordinary case: alive, in a squad, at an ambulance, with a key out')

    -- NOT AN AMBULANCE. Asked of BR.Rescue.isAmbulance so all three ambulance
    -- features mean one thing by the word.
    ok(why(2, 9202) == 'that is not an ambulance',
        'a car parked in the same spot is not an ambulance', why(2, 9202))

    -- TOO FAR. reachM 6 + reachSlackM 2 = 8 on the server's ruling.
    ok(why(2, 9203) ~= nil, 'an ambulance across the map is not "at an ambulance"',
        why(2, 9203))
    buyer.pos.x = 7.0
    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'and the server\'s ruling is forgiving by reachSlackM, so a press that '
            .. 'was legitimate when it was made is not refused by a stale sample')
    buyer.pos.x = 9.0
    ok(why(2, 9201) ~= nil, 'but not forgiving without limit', why(2, 9201))
    buyer.pos.x = 0.0

    -- A VEHICLE THAT HAS BEEN BLOWN UP. `0` IS TRUTHY IN LUA and DoesEntityExist
    -- is a BOOL native, so a bare truth test here would sell a key at a wreck.
    vanish(201)
    ok(why(2, 9201) == 'that vehicle does not exist',
        'an ambulance that has been destroyed is refused -- DoesEntityExist is '
            .. 'a BOOL native and 0 is truthy', why(2, 9201))
    unvanish(201)

    -- A NET ID THAT MEANS NOTHING.
    ok(why(2, 4242) == 'that net id resolves to nothing',
        'and a net id nobody recognises buys nothing', why(2, 4242))

    -- THE BUYER HAS TO BE UP AND IN THE MATCH.
    buyer.state = BR.PlayerState.OUT
    ok(why(2, 9201) ~= nil,
        'an eliminated player cannot buy their own way back', why(2, 9201))
    buyer.state = BR.PlayerState.DBNO
    ok(why(2, 9201) ~= nil, 'and neither can a downed one (#219 Q17 unanswered)',
        why(2, 9201))
    buyer.state = BR.PlayerState.ALIVE

    -- THE MATCH HAS TO BE LIVE.
    m.state = BR.MatchState.ENDED
    ok(why(2, 9201) == 'not in a playing match', 'and not after the match ends')
    m.state = BR.MatchState.PLAYING

    -- NOTHING TO BUY. 25 Volts is not refundable (config/shop.lua), so a squad
    -- with every key already held must not be charged for a no-op.
    dead.reviveKey.held = true
    ok(why(2, 9201) == 'that squad has no outstanding keys',
        'a squad with nothing outstanding is refused rather than charged',
        why(2, 9201))
    dead.reviveKey.held = false

    -- A SOLO HAS NO SQUAD TO BUY FOR.
    buyer.squadId = nil
    ok(why(2, 9201) == 'no squad', 'and a player with no squad buys nothing')
    buyer.squadId = 'A'

    -- AND NOTHING WAS CHARGED THROUGH ANY OF THAT.
    ok(#charges == 0,
        'no refusal reached the market -- the goods must not exist before the '
            .. 'debit, and neither may the debit before the goods are possible',
        #charges)
end

-- ---------------------------------------------------------------------------
describe('buy.grant')
do
    wipe()
    fakeTime = 500000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local d1 = put(1, { squadId = 'A', x = 500.0, y = 500.0 })
    local d2 = put(3, { squadId = 'A', x = 600.0, y = 600.0 })
    local other = put(4, { squadId = 'B', x = 700.0, y = 700.0 })
    BR.ReviveKey.onEliminated(m, 1)
    BR.ReviveKey.onEliminated(m, 3)
    BR.ReviveKey.onEliminated(m, 4)
    d1.state, d2.state, other.state =
        BR.PlayerState.OUT, BR.PlayerState.OUT, BR.PlayerState.OUT

    local buyer = put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    ok(BR.ReviveKey.outstanding('A', 1) == 2, 'the squad has two mates out',
        BR.ReviveKey.outstanding('A', 1))

    local gotOk, gotN
    BR.ReviveKey.buy(2, 9201, function(o, _, n) gotOk, gotN = o, n end)

    -- ═══ THE GOODS DO NOT EXIST BEFORE THE DEBIT DOES ═══
    ok(#charges == 1, 'the purchase went to the market', #charges)
    ok(charges[1].amount == 25, 'for 25 Volts', charges[1].amount)
    ok(d1.reviveKey.held == false and d2.reviveKey.held == false,
        'and NOTHING is granted while DynamoDB is still thinking -- a key handed '
            .. 'out before the write lands is a key a refusal cannot take back')

    -- ═══ A SECOND PRESS DURING THE ROUND TRIP BUYS NOTHING ═══
    --
    -- BR.Market.charge reserves the Volts against the session cache, which
    -- protects the MONEY. It does not protect the GOODS: two different
    -- squadmates are two different sources with two different reservations, so
    -- the market would take 25 from each of them for the same set of keys.
    local buyer2 = put(5, { squadId = 'A', x = 0.0, y = 0.0 })
    local _, whyTwo = BR.ReviveKey.canBuy(5, buyer2, 9201)
    ok(whyTwo == 'a purchase is already in flight',
        'a squadmate pressing buy during the round trip is refused, so one '
            .. 'squad cannot be charged twice for one set of keys', whyTwo)

    -- ═══ A FOURTH MATE GOES OUT WHILE THE MONEY IS IN THE AIR ═══
    --
    -- The set is re-read AFTER the answer rather than captured before it, so
    -- "one purchase buys all revive keys for the squad" is true at the moment it
    -- completes. That is the reading most generous to the payer, and the owner's
    -- sentence is the generous one.
    local d3 = put(6, { squadId = 'A', x = 800.0, y = 800.0 })
    BR.ReviveKey.onEliminated(m, 6)
    d3.state = BR.PlayerState.OUT

    settle(true, nil, 975)

    ok(gotOk == true, 'the purchase completes')
    ok(gotN == 3, 'and covers all three -- including the one eliminated while '
        .. 'the charge was in flight', gotN)
    ok(d1.reviveKey.held == true and d2.reviveKey.held == true
       and d3.reviveKey.held == true, 'every one of the squad\'s keys is held')
    ok(d1.reviveKey.via == 'bought', 'recorded as bought', d1.reviveKey.via)
    ok(other.reviveKey.held == false,
        'and the OTHER squad paid for nothing and got nothing')
    ok(BR.ReviveKey.outstanding('A', 1) == 0, 'the squad has nothing outstanding')

    -- THE GUARD IS RELEASED, so the squad may buy again for a later
    -- elimination. "multiple instances of this are allowed per match".
    local d4 = put(7, { squadId = 'A', x = 900.0, y = 800.0 })
    BR.ReviveKey.onEliminated(m, 7)
    d4.state = BR.PlayerState.OUT
    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'and a later elimination can be bought for again -- "multiple instances '
            .. 'of this are allowed per match"')

    -- A BOUGHT KEY IS IDENTICAL TO A FETCHED ONE (owner, 2026-08-30, Q16). The
    -- `via` field records how it was come by and NOTHING may branch on it.
    ok(BR.ReviveKey.heldFor(1) == BR.ReviveKey.heldFor(3),
        'a bought key answers heldFor exactly as a fetched one does')
end

-- ---------------------------------------------------------------------------
describe('buy.refused-by-the-row')
do
    -- THE CACHE THOUGHT THEY COULD AFFORD IT AND THE ROW DISAGREED. Reachable
    -- whenever the cache is stale -- a console grant, or this licence connected
    -- somewhere else. Nothing may be granted.
    wipe()
    fakeTime = 600000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 500.0, y = 500.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT
    local buyer = put(2, { squadId = 'A', x = 0.0, y = 0.0 })

    local gotOk = nil
    BR.ReviveKey.buy(2, 9201, function(o) gotOk = o end)
    settle(false, 'cannot afford it', nil)

    ok(gotOk == false, 'a refusal is reported as one')
    ok(dead.reviveKey.held == false,
        'and NOTHING is granted -- the keys are exactly where they were')

    -- AND THE IN-FLIGHT GUARD IS RELEASED ON THE REFUSAL PATH TOO. If it were
    -- not, one failed purchase would lock a squad out of buying for the rest of
    -- the match, and the symptom -- "buy does nothing" -- would look like the
    -- feature being broken rather than a leaked flag.
    ok(select(1, BR.ReviveKey.canBuy(2, buyer, 9201)) == true,
        'a squad that was refused may try again -- the guard is released on '
            .. 'every path, because BR.Market.charge always calls back')
end

-- ---------------------------------------------------------------------------
describe('net')
do
    -- THE HANDLER IS REGISTERED AND IT REFUSES RUBBISH. It has no client sender
    -- yet (see the protocol note), so this is the whole of its coverage until
    -- the owner gives the wording the prompt needs.
    ok(handlers[BR.Net.REVIVEKEY_BUY] ~= nil,
        'the buy handler is registered')

    wipe()
    fakeTime = 700000
    matches[1] = { id = 1, state = BR.MatchState.PLAYING }
    _G.source = 2
    handlers[BR.Net.REVIVEKEY_BUY]('not a table')
    handlers[BR.Net.REVIVEKEY_BUY](nil)
    handlers[BR.Net.REVIVEKEY_BUY]({})
    ok(#charges == 0,
        'and a malformed or empty payload charges nobody anything', #charges)
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    -- THE MODULE'S LAST WORDS, ON A FAILURE ONLY. Silenced above so the gate
    -- reads cleanly across twenty-five suites; printed here because a failing
    -- assertion is exactly when what the module thought it was doing is worth
    -- having, and this is the only place it can still be recovered.
    realPrint('\27[2m-- last ' .. #printed .. ' module line(s) --\27[0m')
    for _, line in ipairs(printed) do realPrint('\27[2m' .. line .. '\27[0m') end
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
