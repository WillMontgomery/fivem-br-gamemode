-- Unit tests for the match Volts ledger's SPEND column (#293).
--
-- ═══ THE SUITE THAT LOADS server/market.lua FOR REAL, AND WHY IT HAD TO EXIST
--     ═══
--
-- Until this file, nothing in the tree loaded br_core/server/market.lua.
-- tools/test_shop.lua says so in its own words -- it stubs BR.Market wholesale
-- so the showroom handler can be driven -- and it therefore falls back to
-- asserting on the SOURCE TEXT of BR.Market.charge, which is the strongest
-- statement a stub can make about the function it replaced.
--
-- #293 needs more than that. The rule it adds is not "a field exists", it is
-- WHERE ONE LINE SITS: the match's spend counter moves in the SUCCESS arm of
-- BR.Market.charge and nowhere else, so a refused purchase contributes nothing.
-- The failure mode of getting it wrong is silent and permanent -- a ledger that
-- counts money nobody was charged, on rows nobody will re-derive -- and the case
-- that reaches the refusal arm is precisely the one the session cache thought
-- was affordable, so it is neither rare nor visible from inside the game.
--
-- So this suite stands the real function up against a br_ddb that can be told to
-- say yes, to say no, to error, and to never answer at all.
--
-- ═══ WHAT IT DELIBERATELY DOES NOT TEST ═══
--
-- The three CALLERS. The warmup showroom has tools/test_shop.lua, the gun shop
-- has tools/test_gunshop.lua and the revive key has tools/test_revivekey.lua,
-- and all three stub the charge because what they are about is what happens
-- around it. The counter is not in any of them and does not need to be: it is in
-- the one function they all go through, which is the property being asserted
-- here rather than three times over there.

local RES  = 'resources/[fivem-royale]/'

-- server/market.lua narrates every charge and every refusal, which is exactly
-- what it should do on a live box and exactly what nobody wants in a gate's
-- output. Captured rather than discarded, so an assertion can read the console
-- line if one ever needs to. Same shape tools/test_roster.lua uses.
local realPrint = print
local printed = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
end

-- ---------------------------------------------------------------------------
-- Natives and engine stubs
-- ---------------------------------------------------------------------------

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetConvar(_, d) return d end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerName(src) return 'Player' .. tostring(src) end

-- ═══ THE IDENTITY STUB IS THE POINT OF HALF THIS FILE ═══
--
-- FiveM recycles server ids within the minute, and a DynamoDB write is up to six
-- seconds. So the source that pressed Buy and the source sitting at that number
-- when the answer lands are not necessarily the same human -- and a counter
-- written against the id alone would file one player's purchase against
-- another's match. A stub that derived the license from `src` could not express
-- that at all, which is why this one is a table a test can move.
local licenseOf = {}
function GetNumPlayerIdentifiers(src) return 1 end
function GetPlayerIdentifier(src, _)
    return 'license:' .. (licenseOf[src] or ('test' .. tostring(src)))
end

-- Everything the resource emits, in order. `fired` is server-side (this is how
-- br_ddb is asked anything); `sent` is what a client would receive.
local fired, sent = {}, {}
function TriggerEvent(event, ...) fired[#fired + 1] = { event = event, args = { ... } } end
function TriggerClientEvent(event, target, ...)
    sent[#sent + 1] = { event = event, target = target, args = { ... } }
end

local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = fn
end
function RegisterNetEvent() end
function RegisterCommand() end

--- Dispatch to the resource's own handlers, the way the runtime would.
local function fire(name, src, ...)
    _G.source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

-- br_ddb is present unless a test says otherwise -- `ask` returns immediately
-- with an error when it is not, which is a path worth driving.
local ddbState = 'started'
function GetResourceState() return ddbState end

-- ═══ THE SIX-SECOND TIMEOUT IS HELD, NOT SWALLOWED ═══
--
-- `ask` arms a SetTimeout beside every request so a bridge that never answers
-- cannot leak a pending closure per attempt. A no-op stub would make that path
-- untestable -- and "the bridge never answered" is one of the two ways a charge
-- can fail to be a purchase.
local timers = {}
function SetTimeout(_, fn) timers[#timers + 1] = fn end
local function runTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

-- ---------------------------------------------------------------------------
-- The modules under test, in load order
-- ---------------------------------------------------------------------------

local function loadAt(base, f)
    local chunk, err = loadfile(base .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

for _, f in ipairs({
    'br_lib/shared/enums.lua',      -- defines BR
    'br_lib/shared/protocol.lua',   -- BR.Net.MARKET_STATE / NOTIFY / TUTORIAL_*
    'br_lib/shared/identity.lua',   -- BR.Identity, which market.lua keys on
    'br_lib/shared/xp.lua',         -- BR.Xp; BR.Market.push evaluates the curve
    'br_lib/config/market.lua',     -- BR.Config.MarketIndex, buyable, defaultItem
}) do loadAt(RES, f) end

-- ═══ THE ROSTER IS A STUB AND THAT IS FAITHFUL RATHER THAN LAZY ═══
--
-- What server/market.lua consumes is two functions -- `get` and `licenseOf` --
-- and the real roster.lua is thirty other subsystems' worth of load order to
-- provide them. tools/test_roster.lua already drives the REAL roster's half of
-- this feature (the field on newEntry, the wipe in resetPlayer, the copy onto a
-- results row and a sealed one); this file drives the half that lives in the
-- market. Splitting it that way is what keeps each suite about one file.
--
-- `licenseOf` ANSWERS FOR THE ENTRY, NOT FOR THE SOURCE, which is what makes
-- the recycled-id case expressible: a test can hand slot 7 to a different
-- person by replacing the entry.
local entries = {}
BR.Roster = {
    get = function(src) return entries[src] end,
    licenseOf = function(src)
        local e = entries[src]
        return e and e.license or nil
    end,
}

loadAt(RES, 'br_core/server/market.lua')

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

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

local function reset()
    fired, sent, timers = {}, {}, {}
    for k in pairs(entries) do entries[k] = nil end
    for k in pairs(licenseOf) do licenseOf[k] = nil end
    ddbState = 'started'
end

--- The `req` of the newest request br_ddb was asked, by verb.
--- @param verb string
--- @return integer|nil
local function reqOf(verb)
    for i = #fired, 1, -1 do
        if fired[i].event == verb then return fired[i].args[1] end
    end
    return nil
end

--- How many times a verb has been asked since the counter was zeroed.
local function countOf(verb)
    local n = 0
    for _, f in ipairs(fired) do if f.event == verb then n = n + 1 end end
    return n
end

--- Put a player on the roster with a loaded profile of `balance` Volts.
---
--- THROUGH THE REAL LOAD PATH, not by poking `inv`. The cache is a file-local in
--- server/market.lua and reaching into it would test a shape rather than a
--- behaviour -- and `charge` refuses outright while `loaded` is false, which is
--- a guard worth going through rather than around.
--- @param src integer
--- @param balance integer
local function player(src, balance)
    entries[src] = {
        src = src,
        license = 'license:test' .. tostring(src),
        voltsPickedUp = 0,
        voltsSpent = 0,
    }
    BR.Market.load(src)
    fire('br:ddb:inventoryResult', nil, reqOf('br:ddb:inventoryFetch'),
         { balance = balance, xp = 0, owned = {}, equipped = {}, tutorial = '' },
         {})
end

--- Charge, then let br_ddb answer.
--- @param src integer
--- @param cost integer
--- @param answer table  { ok = boolean, extra = table }
--- @return table  { called = boolean, ok = boolean|nil, why = string|nil, left = integer|nil }
local function charge(src, cost, answer)
    local out = { called = false }
    BR.Market.charge(src, cost, 'test', function(paid, why, left)
        out.called, out.ok, out.why, out.left = true, paid, why, left
    end)
    local req = reqOf('br:ddb:spend')
    if answer and req then
        fire('br:ddb:spendResult', nil, req, answer.ok, answer.extra or {})
    end
    return out
end

local function spentOf(src)
    local e = entries[src]
    return e and e.voltsSpent or nil
end

-- ---------------------------------------------------------------------------
describe('the success arm, and only the success arm')
-- ---------------------------------------------------------------------------
do
    -- ── A SETTLED PURCHASE IS COUNTED ───────────────────────────────────
    reset()
    player(7, 5000)
    local r = charge(7, 1500, { ok = true, extra = { balance = 3500 } })

    ok(r.called and r.ok == true, 'the charge settles', tostring(r.why))
    ok(spentOf(7) == 1500,
        'and the match ledger records exactly what was taken',
        ('got %s'):format(tostring(spentOf(7))))
    -- THE ROW'S OWN FIGURE, not arithmetic: `br:ddb:spend` answers with
    -- UPDATED_NEW and the caller is handed it.
    ok(r.left == 3500, 'the caller is told what is left', tostring(r.left))

    -- ── AND A SECOND ONE ACCUMULATES ────────────────────────────────────
    --
    -- A match is three spend paths and a player may use all of them. An
    -- assignment rather than an addition would report only the last purchase,
    -- which is a plausible-looking number and the wrong one.
    charge(7, 750, { ok = true, extra = { balance = 2750 } })
    ok(spentOf(7) == 2250,
        'two purchases in one match add up rather than replacing each other',
        ('got %s'):format(tostring(spentOf(7))))

    -- ── A REFUSED WRITE ADDS NOTHING ────────────────────────────────────
    --
    -- ═══ THE ASSERTION THIS WHOLE FILE EXISTS FOR ═══
    --
    -- Counting at the reservation instead of at the answer would bank this, and
    -- everything a player could see would look identical: no car, no toast, the
    -- balance they started with, and a ledger quietly claiming they spent 900.
    --
    -- IT IS NOT A HYPOTHETICAL PATH. DynamoDB refuses when the session cache is
    -- stale -- a report award, a console grant, or the same license connected to
    -- a second server -- which is exactly the case the debit was moved into
    -- DynamoDB to catch.
    reset()
    player(8, 5000)
    local refused = charge(8, 900, { ok = false, extra = { refused = 'not enough currency' } })
    ok(refused.called and refused.ok == false, 'a refused write answers false')
    ok(spentOf(8) == 0,
        'AND NOTHING IS ADDED TO THE MATCH LEDGER -- a refusal is not a purchase',
        ('got %s'):format(tostring(spentOf(8))))
    ok(refused.left == nil,
        'and no balance is quoted for a purchase that did not happen')

    -- ── AN ERRORED WRITE ADDS NOTHING EITHER ────────────────────────────
    --
    -- A different arm of the same `if`: throttling and timeouts answer with an
    -- error rather than a refusal, and a counter that treated "we do not know"
    -- as a sale would drift upward on exactly the busy evening when the most
    -- matches are running.
    local errored = charge(8, 900, { ok = false, extra = { error = 'ProvisionedThroughputExceededException' } })
    ok(errored.called and errored.ok == false, 'a failed write answers false too')
    ok(spentOf(8) == 0,
        'and adds nothing -- an unanswered write is not a purchase',
        ('got %s'):format(tostring(spentOf(8))))

    -- ── AND NEITHER DOES A BRIDGE THAT NEVER ANSWERS ────────────────────
    --
    -- The six-second timeout fires the callback with an error and no `ok`, which
    -- is the same arm as above reached from the other direction.
    reset()
    player(9, 5000)
    local hung = { called = false }
    BR.Market.charge(9, 400, 'test', function(paid) hung.called, hung.ok = true, paid end)
    ok(spentOf(9) == 0, 'a charge in flight has bought nothing yet',
        ('got %s'):format(tostring(spentOf(9))))
    runTimers()
    ok(hung.called and hung.ok == false, 'the timeout answers rather than hanging')
    ok(spentOf(9) == 0,
        'and a bridge that never answered adds nothing',
        ('got %s'):format(tostring(spentOf(9))))
end

-- ---------------------------------------------------------------------------
describe('the refusals that never reach DynamoDB')
-- ---------------------------------------------------------------------------
do
    -- The cheap refusals happen before the round trip, so they cannot reach the
    -- success arm at all -- but a counter moved at the top of the function would
    -- catch every one of them, and this is the shape that would make that
    -- obvious.
    reset()
    player(11, 100)

    local poor = charge(11, 750, nil)
    ok(poor.called and poor.ok == false, 'an obviously unaffordable charge is refused here')
    ok(countOf('br:ddb:spend') == 0, 'without costing a round trip',
        ('got %d'):format(countOf('br:ddb:spend')))
    ok(spentOf(11) == 0, 'and nothing is added to the ledger',
        ('got %s'):format(tostring(spentOf(11))))

    local nothing = charge(11, 0, nil)
    ok(nothing.ok == false, 'charging nothing is a caller bug and is refused')
    ok(spentOf(11) == 0, 'and adds nothing')

    -- A NEGATIVE AMOUNT IS THE ONE THAT WOULD MINT MONEY, and it would mint
    -- ledger entries too.
    local negative = charge(11, -750, nil)
    ok(negative.ok == false, 'a negative charge is refused')
    ok(spentOf(11) == 0, 'and adds nothing')

    -- A PROFILE THAT NEVER LOADED. `charge` refuses before it can read a
    -- balance, which is also before it could count anything.
    reset()
    entries[12] = { src = 12, license = 'license:test12', voltsSpent = 0 }
    local unloaded = charge(12, 750, nil)
    ok(unloaded.ok == false, 'a charge against an unloaded profile is refused')
    ok(spentOf(12) == 0, 'and adds nothing')
end

-- ---------------------------------------------------------------------------
describe('the reservation is not the ledger')
-- ---------------------------------------------------------------------------
do
    -- ═══ THE TRAP #293's SURVEY FOUND, PINNED SO NOBODY WALKS INTO IT AGAIN
    --     ═══
    --
    -- server/market.lua already has a field called `spent`. It is an in-flight
    -- RESERVATION: it grows the moment a charge is asked for and is released the
    -- moment DynamoDB answers, on BOTH arms -- so it is zero almost always, it
    -- is never larger than the charges currently waiting, and it is a total of
    -- nothing. Reading it as "what this player has spent" would report zero for
    -- every finished match and a partial figure for the one case where it does
    -- not.
    reset()
    player(13, 5000)

    BR.Market.charge(13, 1500, 'test', function() end)
    local duringFlight = BR.Market.balanceOf(13)
    ok(duringFlight == 3500,
        'a charge in flight is already gone from the spendable balance',
        ('got %s'):format(tostring(duringFlight)))
    ok(spentOf(13) == 0,
        'while the LEDGER is still zero -- nothing has been bought yet',
        ('got %s'):format(tostring(spentOf(13))))

    fire('br:ddb:spendResult', nil, reqOf('br:ddb:spend'), true, { balance = 3500 })
    ok(BR.Market.balanceOf(13) == 3500,
        'the answer moves the reservation into the balance without a flicker',
        ('got %s'):format(tostring(BR.Market.balanceOf(13))))
    ok(spentOf(13) == 1500,
        'and NOW the ledger records it -- the two numbers are not the same thing',
        ('got %s'):format(tostring(spentOf(13))))

    -- ...AND A RELEASED RESERVATION LEAVES THE BALANCE WHERE IT WAS while the
    -- ledger stays put too. Both halves of "a refusal costs nothing".
    BR.Market.charge(13, 1000, 'test', function() end)
    fire('br:ddb:spendResult', nil, reqOf('br:ddb:spend'), false,
         { refused = 'not enough currency', balance = 3500 })
    ok(BR.Market.balanceOf(13) == 3500,
        'a refusal gives the reservation back',
        ('got %s'):format(tostring(BR.Market.balanceOf(13))))
    ok(spentOf(13) == 1500,
        'and leaves the ledger exactly where the settled purchase left it',
        ('got %s'):format(tostring(spentOf(13))))
end

-- ---------------------------------------------------------------------------
describe('a recycled server id is not the same person')
-- ---------------------------------------------------------------------------
do
    -- ═══ SIX SECONDS IS LONG ENOUGH TO BECOME SOMEBODY ELSE ═══
    --
    -- FiveM reuses server ids within the minute and this write can take six
    -- seconds, so the entry sitting at a source when the answer lands may belong
    -- to a different human. server/roster.lua forgets a dozen per-src caches on
    -- disconnect for exactly this reason -- a stale rate-of-fire stamp, a voice
    -- room, a reviver -- and a spend filed against the wrong entry is the same
    -- class of bug with money in it.
    reset()
    player(20, 5000)

    BR.Market.charge(20, 1500, 'test', function() end)

    -- The buyer disconnects inside the round trip and somebody else connects
    -- into their slot. Their roster entry is a NEW one, under a new license.
    entries[20] = { src = 20, license = 'license:stranger', voltsSpent = 0 }

    fire('br:ddb:spendResult', nil, reqOf('br:ddb:spend'), true, { balance = 3500 })

    ok(spentOf(20) == 0,
        'the charge is NOT filed against whoever holds that slot now',
        ('got %s'):format(tostring(spentOf(20))))

    -- ...AND THE SAME PERSON STILL IS. The guard has to refuse a stranger
    -- without refusing the ordinary case, which is every purchase in the game.
    reset()
    player(21, 5000)
    BR.Market.charge(21, 1500, 'test', function() end)
    fire('br:ddb:spendResult', nil, reqOf('br:ddb:spend'), true, { balance = 3500 })
    ok(spentOf(21) == 1500,
        'while a buyer who is still there is counted normally',
        ('got %s'):format(tostring(spentOf(21))))

    -- AND A BUYER WHO IS SIMPLY GONE COSTS NOTHING AND THROWS NOTHING. There is
    -- no roster entry at all, which is the ordinary shape of a disconnect.
    reset()
    player(22, 5000)
    BR.Market.charge(22, 1500, 'test', function() end)
    entries[22] = nil
    local threw = select(2, pcall(function()
        fire('br:ddb:spendResult', nil, reqOf('br:ddb:spend'), true, { balance = 3500 })
    end))
    ok(threw == nil or threw == false,
        'a settled charge for somebody who has left does not throw into the bridge',
        tostring(threw))
end

-- ---------------------------------------------------------------------------
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
    os.exit(1)
end
realPrint(('\27[32m%d passed\27[0m'):format(pass))
