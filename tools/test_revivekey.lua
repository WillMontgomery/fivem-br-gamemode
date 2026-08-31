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

    -- ═══ EVERY WORD IS IN ONE TABLE, AND THERE ARE EXACTLY SIX OF THEM ═══
    --
    -- #219 Q20 used to be unanswered and this suite used to assert the config
    -- held NO strings at all. The owner answered it on 2026-08-30 with a list of
    -- six lines and an instruction to stop waiting on him, so the rule inverted
    -- rather than lapsed: the six are pinned VERBATIM and a seventh is a
    -- failure.
    --
    -- WHY VERBATIM. These are his words. A tidy-up that turned "Buy revive keys
    -- — 25 Volts" into "Buy revive keys (25 Volts)" would be an agent editing
    -- the owner's copy -- the exact thing the standing rule forbids -- and it
    -- would not error anywhere.
    local C = K.copy
    ok(type(C) == 'table', 'the wording lives in one table')
    if type(C) == 'table' then
        local want = {
            take      = 'Take revive key',
            buy       = 'Buy revive keys — 25 Volts',
            revive    = 'Revive teammate',
            collected = 'Revive key collected',
            bought    = 'Revive keys bought',
            expired   = 'Revive key lost',
        }
        local n = 0
        for k, v in pairs(C) do
            n = n + 1
            ok(want[k] == v,
                ('copy.%s is the owner\'s line, character for character'):format(k),
                v)
        end
        ok(n == 6,
            'and there are SIX and no more -- a seventh line is a question for '
                .. 'the owner, not a string to write', n)
    end

    -- ═══ AND NOTHING SPEAKS FROM ANYWHERE BUT THAT TABLE ═══
    --
    -- The point of `copy` is that he can rewrite everything this feature says by
    -- editing one screen. A loose `prompt` or `label` at the top level would be
    -- a second place to look and a second place to drift.
    for _, k in ipairs({ 'prompt', 'label', 'text', 'toast', 'notify',
                         'pickupText', 'boughtText' }) do
        ok(K[k] == nil,
            ('config/revivekey.lua has no top-level `%s` -- every string this '
                .. 'feature speaks is in `copy` and nowhere else'):format(k))
    end

    -- ═══ THE RESURRECTION NUMBERS THAT EXIST, AND THE ONES THAT MUST NOT ═══
    --
    -- The hold and its two reach values are real now and are named here. What is
    -- still absent is everything the SHAPE of the feature deleted rather than
    -- deferred: a key revive stands a player up where they fell and performs no
    -- placement at all, so there is no drop height, no parachute and no landing.
    ok((tonumber(K.reviveHoldMs) or 0) > 0, 'the hold has a duration', K.reviveHoldMs)
    ok((tonumber(K.reviveReachM) or 0) > 0, 'and a reach', K.reviveReachM)
    ok((tonumber(K.reviveSlackM) or 0) > 0,
        'and the server rules with slack on top of it, the way every other '
            .. 'position check in this project does', K.reviveSlackM)
    ok(K.reviveReachM > K.collectM,
        'the revive circle is wider than the collection circle -- collection is '
            .. '"standing on the body", and a hold must not be lost by shifting '
            .. 'your feet',
        ('%s vs %s'):format(K.reviveReachM, K.collectM))

    for _, k in ipairs({ 'dropHeightM', 'parachute', 'maxRevives', 'landingHp' }) do
        ok(K[k] == nil,
            ('config/revivekey.lua has no `%s` -- a key revive puts nobody '
                .. 'anywhere, so there is nothing for it to describe'):format(k))
    end

    -- ═══ AND NO `reviveHp`, WHICH IS THE ONE WORTH ASSERTING ═══
    --
    -- A key revive hands back BR.Config.Match.dbnoReviveHp, read at call time,
    -- because it is the same act as a squadmate's pick-up: somebody standing
    -- over a body in the open for a few seconds. The 100 in config/rescue.lua is
    -- the argued exception, not the rule. A number of its own here would be a
    -- second answer to a question that already has one, free to drift the day
    -- somebody tunes the other.
    ok(K.reviveHp == nil,
        'there is no `reviveHp` -- the health is BR.Config.Match.dbnoReviveHp, '
            .. 'so a key revive and a squad revive cannot come to disagree')
    ok((tonumber(BR.Config.Match.dbnoReviveHp) or 0) > 0,
        'and that number exists to be read', BR.Config.Match.dbnoReviveHp)
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

    -- ONE NOTIFY CALL SITE, AND IT TAKES ITS TEXT AS AN ARGUMENT. `say()` is the
    -- only path from this module to a player's screen. The behavioural half --
    -- that every string leaving it is a member of BR.Config.ReviveKey.copy -- is
    -- asserted in `notify` below, against the real module and a capturing stub;
    -- this half stops a SECOND call site with a literal in it, which is how
    -- invented copy ships wearing the owner's authority.
    -- `notify%(` AND NOT `notify`, because `say()` names it twice: once in the
    -- nil-guard that keeps this module loading on a build with no broadcast
    -- half, and once to call it. The open paren is what makes this count CALL
    -- SITES rather than mentions.
    local _, notifies = code:gsub('BR%.Server%.notify%(', '')
    ok(notifies == 1,
        'server/revivekey.lua reaches a player through exactly one notify call '
            .. 'site -- every word it speaks comes out of the config table',
        notifies)
    ok(code:find('function say%(who, line, tone%)') ~= nil,
        'and that call site takes its text as an argument rather than holding one')

    -- ═══ IT WRITES EXACTLY ONE PLAYER STATE, AND IT IS ALIVE ═══
    --
    -- This suite used to assert the module wrote NO state at all, because
    -- resurrection was step 5 and step 5 did not exist. It does now. What has
    -- not changed is that a state write from here reaches client/natives.lua's
    -- invincibility latch, which is derived from the player state and nothing
    -- else -- so the assertion narrows rather than lapsing: the only transition
    -- this file may author is the one back into the match.
    local _, states = code:gsub('Roster%.setState', '')
    ok(states == 1, 'it writes exactly one player state', states)
    ok(code:find('setState%(src, BR%.PlayerState%.ALIVE%)') ~= nil,
        'and that state is ALIVE -- nothing here eliminates, downs or benches '
            .. 'anybody')

    -- ═══ THE KEY POINT IS SQUAD-ONLY, WHICH IS A PROPERTY OF TWO OTHER FILES ═══
    --
    -- The client needs the coordinates the server rules against, and there are
    -- two places to put them: server/party.lua's squad beacon, which reaches
    -- only the squad, and roster.lua's PUBLIC_FIELDS, which reaches EVERY client
    -- in the match. The second would tell the people who just shot you whether
    -- your squad can get you back -- the difference between pushing a body and
    -- leaving it -- and it would look completely correct in game.
    --
    -- ASSERTED HERE BECAUSE NO SUITE LOADS party.lua, and because the failure is
    -- silent: nothing breaks, nothing errors, and the leak is only visible if
    -- somebody thinks to look.
    local ph = io.open(RES .. 'br_core/server/party.lua', 'r')
    local partySrc = ph and ph:read('a') or ''
    if ph then ph:close() end
    ok(partySrc:find('key = keyRow%(e, now%)') ~= nil,
        'the squad beacon carries the key point')

    local rh = io.open(RES .. 'br_core/server/roster.lua', 'r')
    local rosterSrc = rh and rh:read('a') or ''
    if rh then rh:close() end
    local pub = rosterSrc:match('local PUBLIC_FIELDS = {(.-)}')
    ok(pub ~= nil, 'roster.lua still has a PUBLIC_FIELDS list to check')
    ok(pub ~= nil and not pub:find('reviveKey') and not pub:find('key%s*='),
        'and the roster\'s public view carries neither the key nor its point -- '
            .. 'whether a squad can come back is exactly what the squad that '
            .. 'killed them would like to know', pub)
end

-- ---------------------------------------------------------------------------
-- The server module, with the world stubbed around it.
-- ---------------------------------------------------------------------------
local roster, matches, jobs, handlers = {}, {}, {}, {}
local charges, chargeAnswer

--- Everything the module sent a client, in order. { ev, src, d }
---
--- ORDERED AND NOT KEYED, because two of the properties under test are about
--- ORDER rather than content: BR.Net.REVIVED must leave before the roster flips
--- to ALIVE, and the reviver's `done` must arrive at all. A table keyed on event
--- name would answer neither.
local sent = {}

--- Every notice the module put on a player's screen. { who, text, tone }
local said = {}

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
        -- ═══ TWO WRITERS, BECAUSE THE REVIVE USES BOTH ═══
        --
        -- `update` is how a health number reaches the ledger and `setState` is
        -- how the roster learns somebody is back in the match. They are stubbed
        -- rather than mocked -- they really do write the entry -- because every
        -- assertion in `revive.brings-back` below is about what the entry LOOKS
        -- LIKE afterwards, and a mock that only recorded the call would be
        -- testing that the module said the words.
        update = function(src, patch)
            local e = roster[src]
            if not e then return end
            for k, v in pairs(patch) do e[k] = v end
        end,
        setState = function(src, state)
            local e = roster[src]
            if not e then return end
            -- ORDER IS THE THING UNDER TEST HERE, so the stub records WHEN the
            -- flip happened relative to the client events. server/combat.lua's
            -- reviveHeld is explicit that REVIVED must go first: a client left
            -- holding a corpse while the server calls it ALIVE is the state the
            -- server-observed death check exists to eliminate, and it would
            -- eliminate them.
            e.state = state
            sent[#sent + 1] = { ev = '<setState>', src = src, d = state }
        end,
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
    -- ═══ notify IS PRESENT NOW, AND CAPTURED RATHER THAN SILENCED ═══
    --
    -- It used to be deliberately ABSENT, so that copy added to the module would
    -- throw and take the suite down. That guard has been replaced by two better
    -- ones: the source check above (exactly one call site, taking its text as an
    -- argument) and the `notify` block below, which asserts that every string
    -- reaching this stub is a member of BR.Config.ReviveKey.copy. A missing
    -- function could only ever prove that nothing was said; this proves that
    -- what was said is the owner's.
    BR.Server = {
        matches = matches,
        notify  = function(who, text, tone)
            said[#said + 1] = { who = who, text = text, tone = tone }
        end,
    }
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
    _G.TriggerClientEvent = function(ev, src, d)
        sent[#sent + 1] = { ev = ev, src = src, d = d }
    end

    loadCore('br_core/server/revivekey.lua')
end

--- Forget everything the module sent and said.
local function hush()
    for i = #sent, 1, -1 do sent[i] = nil end
    for i = #said, 1, -1 do said[i] = nil end
end

--- The first record of an event, or nil.
local function firstSent(ev)
    for i, s in ipairs(sent) do
        if s.ev == ev then return s, i end
    end
    return nil, nil
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
    hush()
end

local sweep = jobs['revivekey.sweep']
local hold  = jobs['revivekey.hold']

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
-- Spending one.
-- ---------------------------------------------------------------------------

--- One mate OUT with a key their squad owns, and one live mate standing on it.
---
--- THE ELIMINATED PLAYER'S ENTRY IS DIRTIED ON PURPOSE -- placement, diedAt,
--- engineHp, a storm ledger -- because the interesting half of `bringBack` is
--- what it CLEARS. An entry that was clean before the revive would let every one
--- of those assertions pass against a function that does nothing.
--- @param opts table|nil { held, t, dist }
local function downed(opts)
    opts = opts or {}
    wipe()
    fakeTime = opts.t or 1000000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m

    local dead = put(1, { squadId = 'A', x = 100.0, y = 100.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state    = BR.PlayerState.OUT
    dead.placement = 5
    dead.diedAt    = fakeTime
    dead.engineHp  = 0.0
    dead.killedByLicense = 'license:deadbeef'
    dead.hp        = 0.0
    if opts.held ~= false then dead.reviveKey.held = true end

    local mate = put(2, { squadId = 'A',
                          x = 100.0 + (opts.dist or 1.0), y = 100.0 })
    hush()
    return m, dead, mate
end

local function press(src, target)
    _G.source = src
    handlers[BR.Net.REVIVEKEY_START]({ target = target })
end

local function release(src)
    _G.source = src
    handlers[BR.Net.REVIVEKEY_STOP]()
end

--- Why the last press was refused, according to the ring the server took down.
local function refusal()
    local s = firstSent(BR.Net.REVIVEKEY_PROGRESS)
    if not s or not s.d or not s.d.cancelled then return nil end
    return s.d.reason
end

-- ---------------------------------------------------------------------------
describe('revive.registered')
do
    ok(hold ~= nil, 'the hold stepper registered itself on the scheduler')
    ok(handlers[BR.Net.REVIVEKEY_START] ~= nil, 'the start handler is registered')
    ok(handlers[BR.Net.REVIVEKEY_STOP] ~= nil, 'the stop handler is registered')
    ok(BR.Net.REVIVEKEY_START ~= BR.Net.REVIVE_START,
        'and it is NOT the DBNO revive\'s event -- that one\'s ruling refuses '
            .. 'any target who is not down, and its stepper only ever walks '
            .. 'DBNO entries, so an OUT player would never be stepped')
end

-- ---------------------------------------------------------------------------
describe('revive.ruling')
do
    -- ═══ AN UNCLAIMED KEY IS NOT A REVIVE ═══
    --
    -- The one refusal that is the whole shape of the feature: a key lying on the
    -- ground is something to WALK TO or BUY. Only once the squad owns it is
    -- there anything to spend. Get this wrong and the 25 Volts buys nothing that
    -- proximity did not already give away.
    local _, dead = downed({ held = false })
    press(2, 1)
    ok(refusal() == 'that key is not held yet',
        'a key nobody has collected or bought cannot be spent', refusal())
    ok(dead.reviveKey.byS == nil, 'and no claim is written')

    -- THE TARGET HAS TO BE OUT. A live squadmate has no key to spend and a
    -- downed one is server/combat.lua's business, not this file's.
    downed()
    roster[1].state = BR.PlayerState.ALIVE
    hush(); press(2, 1)
    ok(refusal() ~= nil and refusal():find('not out') ~= nil,
        'a target who is not OUT is refused', refusal())

    downed()
    roster[1].state = BR.PlayerState.DBNO
    hush(); press(2, 1)
    ok(refusal() ~= nil and refusal():find('not out') ~= nil,
        'and so is one who is merely downed -- that is the DBNO revive, and it '
            .. 'costs the squad nothing', refusal())

    -- THE REVIVER HAS TO BE UP. A dead player cannot pick anybody up, and a
    -- downed one crawling at 0.55 m/s is not standing over anything.
    for _, st in ipairs({ BR.PlayerState.OUT, BR.PlayerState.DBNO }) do
        downed()
        roster[2].state = st
        hush(); press(2, 1)
        ok(refusal() ~= nil and refusal():find('the reviver is') ~= nil,
            ('a reviver who is %s is refused'):format(st), refusal())
    end

    -- SQUADS. The key is owned by a squad and spent by that squad.
    downed()
    roster[2].squadId = 'B'
    hush(); press(2, 1)
    ok(refusal() == 'different squads', 'an enemy cannot spend your key', refusal())

    -- ═══ AND THE MATCH HAS TO BE LIVE, WHICH IS THE LATE-GAME ANSWER ═══
    --
    -- server/combat.lua carries the write-up of what a clock belonging to a
    -- finished match did last time: it eliminated the winner and stamped a death
    -- over VICTORY ROYALE. A hold completing after the results are published
    -- would be the same shape in the other direction.
    for _, st in ipairs({ BR.MatchState.ENDED, BR.MatchState.CLEANUP,
                          BR.MatchState.WARMUP }) do
        local m = downed()
        m.state = st
        hush(); press(2, 1)
        ok(refusal() == 'not in a playing match',
            ('a match in %s revives nobody'):format(st), refusal())
    end

    -- REACH, MEASURED TO THE KEY'S OWN POINT AND NOT TO THE BODY.
    downed({ dist = 50.0 })
    press(2, 1)
    ok(refusal() ~= nil and refusal():find('from the key') ~= nil,
        'a reviver across the map is refused, and the reason carries the number',
        refusal())

    -- THE SLACK IS ON THE SERVER'S SIDE, and it is the forgiving direction:
    -- a client draws the plate at reviveReachM and the server rules at
    -- reviveReachM + reviveSlackM, so there is no position at which the plate is
    -- up and the hold is refused on geometry.
    local dist = K.reviveReachM + (K.reviveSlackM / 2)
    downed({ dist = dist })
    press(2, 1)
    ok(roster[1].reviveKey.byS == 2,
        'and one just outside the drawn circle is allowed, because the server '
            .. 'position sample is up to a quarter of a second old',
        dist)
end

-- ---------------------------------------------------------------------------
describe('revive.hold')
do
    -- ═══ THE HEARTBEAT MUST NOT RESTART THE CLOCK ═══
    --
    -- The client re-asserts every 250ms. If a re-assertion re-armed the hold,
    -- the progress would reset four times a second and the ring would never
    -- finish -- which is exactly the symptom "I hold the input, the ring fills
    -- up, but then nothing happens" (owner, playtest, on the DBNO path).
    local _, dead = downed()
    press(2, 1)
    local from = dead.reviveKey.from
    ok(dead.reviveKey.byS == 2, 'the first press arms the hold')
    fakeTime = fakeTime + 250
    press(2, 1)
    ok(dead.reviveKey.from == from,
        'and a re-assertion is a heartbeat, NOT a new hold -- it must not '
            .. 'restart the progress')
    ok(dead.reviveKey.beat == fakeTime, 'but it does refresh the deadline')

    -- ═══ FIRST HAND ON WINS ═══
    --
    -- server/combat.lua's rule verbatim: two mates on one body is not twice as
    -- fast, and it must not restart the clock for whoever pressed second.
    local mate2 = put(3, { squadId = 'A', x = 101.0, y = 100.0 })
    mate2.state = BR.PlayerState.ALIVE
    hush(); press(3, 1)
    ok(dead.reviveKey.byS == 2, 'a second presser does not take the key')
    ok(dead.reviveKey.from == from, 'and does not restart it')
    ok(refusal() ~= nil and refusal():find('taken') ~= nil,
        'and is told so -- their ring comes down rather than filling over a hold '
            .. 'that is not theirs', refusal())

    -- ═══ SILENCE IS A RELEASE ═══
    --
    -- The bug this closes shipped once already: "a brief tap completed a whole
    -- revive" (owner, 2026-08-09) because the STOP was raised and did not land.
    -- With no beat requirement, a lost STOP costs the whole interaction; with
    -- one, it costs a fraction of a second.
    fakeTime = fakeTime + (K.reviveBeatMs or 1000) + 250
    hush(); hold()
    ok(dead.reviveKey.byS == nil, 'a hold whose holder went quiet is dropped')
    ok(refusal() == 'went quiet', 'and the reason says so', refusal())
    ok(roster[1].state == BR.PlayerState.OUT,
        'and nobody was revived by a key nobody was holding')

    -- ...AND THE KEY IS STILL THERE. A dropped hold is not a spent key.
    ok(dead.reviveKey.held == true,
        'the key survives a hold that failed -- it is spent by a COMPLETED '
            .. 'revive and by nothing else')

    -- A RELEASE ENDS IT AT ONCE.
    downed()
    press(2, 1)
    hush(); release(2)
    ok(roster[1].reviveKey.byS == nil, 'letting go ends the hold')
    ok(refusal() == 'released', 'and says which', refusal())

    -- WALKING OFF ENDS IT, AND THE STEPPER IS WHAT NOTICES.
    downed()
    press(2, 1)
    roster[2].pos.x = 900.0
    fakeTime = fakeTime + 250
    hush(); hold()
    ok(roster[1].reviveKey.byS == nil, 'walking away ends the hold')
    ok(refusal() ~= nil and refusal():find('from the key') ~= nil,
        'and the reason carries the distance, which is what tells a playtest '
            .. 'apart from a client that is re-arming', refusal())

    -- ═══ A MATCH THAT ENDS UNDER A RUNNING HOLD ═══
    local m = downed()
    press(2, 1)
    m.state = BR.MatchState.ENDED
    fakeTime = fakeTime + (K.reviveHoldMs or 6000) + 250
    hush(); hold()
    ok(roster[1].state == BR.PlayerState.OUT,
        'a hold that would have completed after the match ended stands nobody '
            .. 'up -- the results are published and the placements awarded')
    ok(refusal() == 'not in a playing match', 'and the ring comes down', refusal())

    -- ═══ AND ONE THAT RUNS ITS COURSE ═══
    downed()
    press(2, 1)
    fakeTime = fakeTime + math.floor((K.reviveHoldMs or 6000) / 2)
    hush(); press(2, 1); hold()
    ok(roster[1].state == BR.PlayerState.OUT, 'half way through, nobody is up')
    local prog = firstSent(BR.Net.REVIVEKEY_PROGRESS)
    ok(prog ~= nil and prog.d.done == nil and prog.d.cancelled == nil,
        'and the holder is being told a percentage rather than an ending')

    fakeTime = fakeTime + math.floor((K.reviveHoldMs or 6000) / 2) + 1
    hush(); press(2, 1); hold()
    ok(roster[1].state == BR.PlayerState.ALIVE, 'and at the end, they are back in')
end

-- ---------------------------------------------------------------------------
describe('revive.brings-back')
do
    local _, dead, mate = downed()
    dead.hp = 0.0
    press(2, 1)
    fakeTime = fakeTime + (K.reviveHoldMs or 6000) + 1
    hush(); press(2, 1); hold()

    ok(dead.state == BR.PlayerState.ALIVE, 'the subject is in the match again')
    ok(dead.hp == (BR.Config.Match.dbnoReviveHp + 0.0),
        'on the same health a squadmate\'s pick-up hands back, not on 100 and '
            .. 'not on a number of this feature\'s own', dead.hp)
    ok(dead.armour == 0.0, 'with no armour -- theirs is on the ground with the '
        .. 'rest of their kit')

    -- ═══ THE KEY IS SPENT, AND SPENT MEANS GONE ═══
    --
    -- `held = false` would put it back on the market: `forSquad` filters on the
    -- record EXISTING, so nil is the only representation of "spent" that a
    -- second purchase cannot resurrect.
    ok(dead.reviveKey == nil, 'the key is nilled, not un-held')
    ok(BR.ReviveKey.outstanding('A', 1) == 0,
        'so the squad has nothing outstanding and cannot buy them back a second '
            .. 'time for the same death')

    -- ═══ EVERYTHING THE ELIMINATION WROTE IS UNWRITTEN ═══
    ok(dead.placement == nil,
        'the placement goes -- they have not finished anywhere')
    ok(dead.diedAt == nil, 'and so does the moment they stopped surviving')
    ok(dead.engineHp == nil,
        'and the last engine-health sample -- or the 1Hz server-observed death '
            .. 'check reads a stale corpse reading and eliminates them again a '
            .. 'second into the life they were just given')
    ok(dead.killedByLicense == nil,
        'and the spectate camera\'s memory of who killed them, so a LATER death '
            .. 'with no killer does not inherit this one')
    ok((dead.healthSettleUntil or 0) > fakeTime,
        'the health audit is told to expect the crossover, so a ledger that '
            .. 'leads the ped is not logged as a client inventing health',
        dead.healthSettleUntil)

    -- ═══ THE ORDER: THE PED IS TOLD BEFORE THE LEDGER IS ═══
    --
    -- protocol.lua's REVIVED note: a client left holding a corpse while the
    -- server calls it ALIVE is exactly the state the server-observed death check
    -- exists to eliminate -- and it would eliminate them.
    local _, iRev = firstSent(BR.Net.REVIVED)
    local _, iState = firstSent('<setState>')
    ok(iRev ~= nil, 'the resurrection is sent to the machine that owns the ped')
    ok(iRev ~= nil and iState ~= nil and iRev < iState,
        'and it goes BEFORE the roster says ALIVE', ('%s vs %s'):format(iRev, iState))

    local hs = firstSent(BR.Net.HEALTH_SYNC)
    ok(hs ~= nil and hs.d.hp == BR.Config.Match.dbnoReviveHp,
        'the client is told what the number IS, absolutely, the way every other '
            .. 'health correction in this project is')

    -- THE REVIVER IS CREDITED AND HIS RING IS CLOSED.
    ok(mate.revives == 1, 'the reviver is credited with the revive', mate.revives)
    local done = nil
    for _, s in ipairs(sent) do
        if s.ev == BR.Net.REVIVEKEY_PROGRESS and s.d.done then done = s end
    end
    ok(done ~= nil and done.src == 2, 'and their ring is told it landed')

    -- ═══ AND NOT ONE WORD IS SPOKEN ═══
    --
    -- The owner gave six lines and a completed revive is not one of them.
    -- BR.Combat.revive ends with "%s picked you up." / "You picked %s up." and
    -- this path deliberately does not borrow them: the subject watches their own
    -- body stand up, the reviver's ring closes, and there is no seventh string.
    ok(#said == 0,
        'a completed revive says nothing -- there is no line for it and none '
            .. 'may be invented', #said)
end

-- ---------------------------------------------------------------------------
describe('revive.storm')
do
    -- ═══ THE BUG THIS BLOCK EXISTS FOR, AND IT IS INVISIBLE IN A PLAYTEST ═══
    --
    -- server/storm.lua seeds its damage ledger from `e.stormHp` and only ever
    -- clamps it DOWN. Nothing clears that field on death -- only
    -- BR.Match.resetPlayer and stepping back inside the circle do. So a player
    -- the storm killed, revived at their corpse and therefore STILL OUTSIDE THE
    -- WALL, carries a stormHp at or below zero and is eliminated again on the
    -- very next storm tick, regardless of the health they were just handed.
    --
    -- WHAT IT WOULD LOOK LIKE IN GAME: a squad spends 25 Volts and six seconds
    -- of standing in the open, their mate stands up on 30 hp, and dies again
    -- about a second later for no reason anyone can see. Being outside the wall
    -- is still a bad place to be picked up -- that is the rule -- but the damage
    -- has to start from the health they were given.
    local _, dead = downed()
    dead.stormHp     = -12.0
    dead.lastStormAt = fakeTime

    press(2, 1)
    fakeTime = fakeTime + (K.reviveHoldMs or 6000) + 1
    hush(); press(2, 1); hold()

    ok(dead.state == BR.PlayerState.ALIVE, 'the storm\'s victim is back up')
    ok(dead.stormHp == nil,
        'and the storm ledger is cleared -- a revived player must not be killed '
            .. 'again by a number recorded before they died', dead.stormHp)
    ok(dead.lastStormAt == nil,
        'and its clock with it, so the first tick after the revive measures from '
            .. 'now rather than from before the death')
end

-- ---------------------------------------------------------------------------
describe('revive.console')
do
    -- `/brkey revive` RUNS THE SAME PATH, WHICH IS server/rescue.lua's RULE FOR
    -- /brrescue: an admin verb that took a shortcut would be testing itself.
    local _, dead = downed()
    local okRev, whyRev = BR.ReviveKey.revive(1)
    ok(okRev == true, 'the console can finish a revive', whyRev)
    ok(dead.state == BR.PlayerState.ALIVE, 'and it goes through the same door')
    ok(dead.reviveKey == nil, 'spending the key exactly as a hold does')

    -- ...AND IT IS NOT A CHEAT CODE. The ruling in front of it is the real one.
    downed({ held = false })
    local ok2, why2 = BR.ReviveKey.revive(1)
    ok(ok2 == false and why2 == 'that key is not held yet',
        'a squad that does not own the key cannot have one handed to them from '
            .. 'the console either', why2)

    local m = downed()
    m.state = BR.MatchState.ENDED
    local ok3, why3 = BR.ReviveKey.revive(1)
    ok(ok3 == false and why3 == 'not in a playing match',
        'and a finished match refuses the console too', why3)

    local ok4 = BR.ReviveKey.revive(999)
    ok(ok4 == false, 'a player who is not on the roster is refused')

    -- ═══ AND A NAMED REVIVER IS RULED ON, NOT TAKEN AT FACE VALUE ═══
    --
    -- `/brkey revive <subject> <reviver>` takes the second id from a console
    -- line, and the whole point of the verb is that it runs the SAME ruling a
    -- player's six seconds run. Without this case the named-reviver branch is
    -- never driven at all: every other assertion in this block calls it with one
    -- argument and exercises the other branch. Found by mutation -- deleting the
    -- reviveAllowed() call from that branch left this suite green.
    downed({ dist = 90.0 })
    local ok5, why5 = BR.ReviveKey.revive(1, 2)
    ok(ok5 == false and why5 ~= nil and why5:find('from the key') ~= nil,
        'a named reviver standing across the map is refused from the console '
            .. 'exactly as they are in game', why5)
    ok(roster[1].state == BR.PlayerState.OUT, 'and nobody stood up')

    downed()
    roster[2].state = BR.PlayerState.OUT
    local ok6, why6 = BR.ReviveKey.revive(1, 2)
    ok(ok6 == false and why6 ~= nil and why6:find('the reviver is') ~= nil,
        'and so is a dead one', why6)
end

-- ---------------------------------------------------------------------------
describe('notify')
do
    -- ═══ EVERY WORD THIS MODULE SPEAKS IS ONE OF THE OWNER'S SIX ═══
    --
    -- The source check above stops a SECOND notify call site being added. This
    -- is the half that matters: it drives the real module through all three of
    -- its speaking paths and asserts that what came out is character for
    -- character what config/revivekey.lua says. A helpful default in an `or`
    -- would pass the source check and fail here.
    local byText = {}
    for k, v in pairs(K.copy) do byText[v] = k end

    -- COLLECTION.
    wipe()
    fakeTime = 2000000
    local m = { id = 1, state = BR.MatchState.PLAYING }
    matches[1] = m
    local dead = put(1, { squadId = 'A', x = 300.0, y = 300.0 })
    BR.ReviveKey.onEliminated(m, 1)
    dead.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 300.0, y = 300.5 })
    hush(); sweep()
    ok(#said == 1, 'walking over a key says one thing', #said)
    ok(said[1] and said[1].text == K.copy.collected,
        'and it is the owner\'s line for it', said[1] and said[1].text)
    -- THE WHOLE SQUAD, INCLUDING THE ONE WHO IS OUT. "The key is picked up by
    -- the player, then owned by the SQUAD" -- and the person it brings back is
    -- watching their own body, which makes them the one who most wants to know.
    ok(said[1] and type(said[1].who) == 'table' and #said[1].who == 2,
        'told to the whole squad, the eliminated player included',
        said[1] and said[1].who and #said[1].who)

    -- EXPIRY. THE PICKUP GOES; THE KEY DOES NOT.
    wipe()
    fakeTime = 3000000
    matches[1] = { id = 1, state = BR.MatchState.PLAYING }
    local dead2 = put(1, { squadId = 'A', x = 400.0, y = 400.0 })
    BR.ReviveKey.onEliminated(matches[1], 1)
    dead2.state = BR.PlayerState.OUT
    put(2, { squadId = 'A', x = 900.0, y = 900.0 })
    fakeTime = fakeTime + K.expiryMs + 1000
    hush(); sweep()
    ok(#said == 1 and said[1].text == K.copy.expired,
        'a pickup running out says the owner\'s line for it',
        said[1] and said[1].text)
    hush(); sweep()
    ok(#said == 0,
        'and says it ONCE -- the record keeps being swept because it is still '
            .. 'buyable for the rest of the match', #said)

    -- PURCHASE. ONE PRESS, ONE SENTENCE, HOWEVER MANY KEYS IT COVERED.
    wipe()
    fakeTime = 4000000
    matches[1] = { id = 1, state = BR.MatchState.PLAYING }
    for _, id in ipairs({ 1, 3, 4 }) do
        local d = put(id, { squadId = 'A', x = 500.0 + id, y = 500.0 })
        BR.ReviveKey.onEliminated(matches[1], id)
        d.state = BR.PlayerState.OUT
    end
    put(2, { squadId = 'A', x = 0.0, y = 0.0 })
    hush()
    BR.ReviveKey.buy(2, 9201)
    settle(true, nil, 500)
    ok(#said == 1 and said[1].text == K.copy.bought,
        'one purchase says one thing, not one thing per key', #said)

    -- AND NOTHING ELSE EVER CAME OUT.
    local strayed = nil
    for _, s in ipairs(said) do
        if byText[s.text] == nil then strayed = s.text end
    end
    ok(strayed == nil,
        'no string left this module that is not one of the owner\'s six',
        strayed)
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
