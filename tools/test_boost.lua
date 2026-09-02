-- Unit tests for the vehicle boost: the ramp curve, the 4s/6s budget, the
-- partial spend, the fuel surcharge and the claim ceiling.
--
-- ═══ WHY THIS IS A SUITE AND NOT THREE ASSERTIONS IN test_shared ═══
--
-- Every number the owner gave for this feature is a number about TIME, and the
-- interesting properties are all relationships between two of them:
--
--   * a full boost is 4 seconds, of which the first 2 are a ramp -- so the ramp
--     must be complete HALFWAY THROUGH and stay complete;
--   * a partial spend gets a proportionally shorter ramp and is not rescaled;
--   * the meter empties in 4 seconds and refills in 6, so the sustainable duty
--     cycle is exactly 40% -- and the server's claim ceiling has to converge on
--     the same 40% or the fuel surcharge stops describing anything;
--   * ending a boost does NOTHING, which in a pure module means there is no
--     function that could -- asserted here by its absence being deliberate.
--
-- None of that is visible in a single call. All of it is arithmetic, so all of
-- it can be tested without a running FXServer, which is the same bargain
-- tools/test_fuel.lua strikes for the fuel solver.
--
-- ═══ WHAT THIS DELIBERATELY DOES NOT COVER ═══
--
-- Anything that needs the engine to be honest. Whether APPLY_FORCE_TO_ENTITY
-- with bScaleByMass really produces a velocity change of `dv` m/s, whether
-- `veh_nitrous` renders where the exhaust bone says, whether a boosting car
-- pressed into a wall behaves, and above all whether four seconds of +30 mph
-- FEELS like a boost -- none of those is a question a Lua process can be asked.
-- They are named in the report instead.

local realPrint = print
function print() end

BR = BR or {}

local ROOT = 'resources/[fivem-royale]/'
local function load(f)
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/geo.lua',
    -- ORDERED, AND THE ORDER IS THE MANIFEST'S. config/boost.lua derives
    -- `addMps` from BR.BoostSolve.MPH at load time, so the solver comes first --
    -- exactly as br_core/fxmanifest.lua declares the pair. A suite that loaded
    -- them the other way round would pass on a nil constant.
    'br_lib/shared/boost_solve.lua',
    'br_lib/config/boost.lua',
}) do load(f) end

local S = BR.BoostSolve
local C = BR.Config.Boost

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
local function near(a, b, eps)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= (eps or 0.001)
end

-- ---------------------------------------------------------------------------
describe('the numbers the owner gave')
-- ---------------------------------------------------------------------------
--
-- THE CONFIG IS UNDER TEST HERE, NOT JUST THE SOLVER. Every figure below is a
-- direct quote from #203, and a suite that only exercised the arithmetic would
-- pass just as happily on a three-second boost. These are the assertions that
-- fail when somebody "tidies" a constant.

ok(C.capacityMs == 4000.0, 'a boost lasts four seconds', C.capacityMs)
ok(C.rechargeMs == 6000.0, 'and recharges over six', C.rechargeMs)
ok(C.rampMs == 2000.0, 'the ramp is the first two seconds', C.rampMs)
ok(C.addMph == 30.0, 'it is worth thirty miles an hour', C.addMph)
ok(C.fuelMultiplier == 1.5, 'and burns fuel 50% faster', C.fuelMultiplier)

-- 30 mph = 13.4112 m/s. ONE CONVERSION, and this is the assertion that catches
-- a second copy of 0.44704 drifting from the first.
ok(near(S.MPH, 0.44704, 1e-9), 'one mile per hour is 0.44704 m/s', S.MPH)
ok(near(C.addMps, 13.4112, 1e-4), 'so the boost is 13.41 m/s', C.addMps)

-- The derived ceiling: 13.4112 / 2.0 seconds = 6.7056 m/s^2, doubled by the
-- headroom. Asserted as the ARITHMETIC rather than as the literal, so changing
-- 30 mph or 2 seconds moves this with it and only a broken derivation fails.
ok(near(C.maxAccelMps2, (C.addMps / (C.rampMs / 1000.0)) * C.accelHeadroom),
   'the acceleration ceiling is the ramp rate times the headroom',
   C.maxAccelMps2)
ok(C.maxAccelMps2 > C.addMps / (C.rampMs / 1000.0),
   'and it is strictly above what following the ramp costs',
   'a ceiling at or below the ramp rate cannot track it against drag')

-- ---------------------------------------------------------------------------
describe('the ramp')
-- ---------------------------------------------------------------------------

ok(S.ramp(0, 2000) == 0.0, 'starts at nothing')
ok(near(S.ramp(1000, 2000), 0.5), 'is half way at one second')
ok(S.ramp(2000, 2000) == 1.0, 'is complete at two')

-- ═══ THE CLAUSE THAT MAKES 4s AND 2s TWO DIFFERENT NUMBERS ═══
--
-- "The acceleration should be over the course of the FIRST 2 seconds." A ramp
-- that kept climbing to the end of the boost would make the last two seconds an
-- acceleration rather than a hold, and the car would arrive somewhere north of
-- +30 mph. It must be pinned.
ok(S.ramp(3000, 2000) == 1.0, 'and stays complete through second three')
ok(S.ramp(4000, 2000) == 1.0, 'and through second four')
ok(S.ramp(60000, 2000) == 1.0, 'and would stay complete forever')

ok(S.ramp(-500, 2000) == 0.0, 'a negative elapsed is the start, not below it')
ok(S.ramp(1000, 0) == 1.0, 'a zero ramp is fully up immediately, not a divide')
ok(S.ramp(1000, -5) == 1.0, 'and so is a negative one')
ok(S.ramp(0 / 0, 2000) == 0.0, 'a NaN elapsed does not propagate')

-- ---------------------------------------------------------------------------
describe('the target speed')
-- ---------------------------------------------------------------------------

-- ═══ RELATIVE, WHICH IS THE CLAUSE MOST EASILY READ AS A CAP ═══
--
--   "a speed 30mph faster than what it was doing when they pressed it"
--
-- Two cars pressing at different speeds must get different targets, and the
-- DIFFERENCE between them must be the same. A capped implementation passes the
-- first of these and fails the second.
local slow = S.target(10.0, C.addMps, 2000, C.rampMs)
local fast = S.target(40.0, C.addMps, 2000, C.rampMs)
ok(near(slow, 10.0 + C.addMps), 'a car at 10 m/s is asked for 10 + 13.41')
ok(near(fast, 40.0 + C.addMps), 'a car at 40 m/s is asked for 40 + 13.41')
ok(near(fast - slow, 30.0), 'so the gap between them is untouched -- not a cap')

ok(near(S.target(20.0, C.addMps, 0, C.rampMs), 20.0),
   'at the instant of the press the target is what they were already doing')
ok(near(S.target(20.0, C.addMps, 1000, C.rampMs), 20.0 + C.addMps * 0.5),
   'and half the boost is banked at one second')

ok(near(S.target(-5.0, C.addMps, 2000, C.rampMs), C.addMps),
   'a reversing car is treated as stationary, not as negative')
ok(near(S.target(20.0, 0 / 0, 2000, C.rampMs), 20.0),
   'a NaN addition adds nothing rather than poisoning the target')

-- ═══ AND A NEGATIVE ADDITION ADDS NOTHING RATHER THAN SUBTRACTING ═══
--
-- MUTATION TESTING FOUND THIS GAP. A misconfigured `addMph` of -30 would, with
-- the floor removed, produce a target BELOW the speed at the press -- and the
-- controller would then be asking the car to slow down, which is the single
-- thing the spec forbids outright. A config typo must cost the feature, never
-- reverse it.
ok(near(S.target(20.0, -13.0, 2000, C.rampMs), 20.0),
   'a negative addition is floored, so the target never drops below the base')

-- ---------------------------------------------------------------------------
describe('the meter')
-- ---------------------------------------------------------------------------

--- Spend or earn for `ms`, in 16ms frames, starting from `budget`.
--- @return number budget
--- @return number spent  total actually spent
local function run(budget, ms, boosting)
    local spent, left = 0.0, budget
    local done = 0
    while done < ms do
        local dt = math.min(16, ms - done)
        local s
        left, s = S.step(left, dt, boosting, C.capacityMs, C.rechargeMs)
        spent = spent + s
        done = done + dt
    end
    return left, spent
end

-- FOUR SECONDS OF HOLD EMPTIES A FULL METER, and not a millisecond more.
local left, spent = run(C.capacityMs, 4000, true)
ok(near(left, 0.0), 'four seconds of boost empties a full meter', left)
ok(near(spent, 4000.0), 'and spends exactly four seconds of it', spent)

-- AND THE FIFTH SECOND COSTS NOTHING, because there is nothing there. This is
-- "running out of boost" as arithmetic: the spend goes to zero and the meter
-- does not go negative.
local left5, spent5 = run(0.0, 1000, true)
ok(left5 == 0.0, 'an empty meter held down stays empty', left5)
ok(spent5 == 0.0, 'and spends nothing', spent5)

-- SIX SECONDS OF NOT BOOSTING REFILLS IT. Empty to full, which is what
-- "recharge over 6 seconds" says -- not "6 seconds per second of boost".
local back = run(0.0, 6000, false)
ok(near(back, C.capacityMs, 1.0), 'six seconds refills an empty meter', back)

-- ═══ AND IT IS NOT FULL BEFORE THEN, WHICH IS THE HALF THE CLAMP HIDES ═══
--
-- MUTATION TESTING FOUND THIS GAP AND IT IS WORTH THE EXTRA THREE LINES. The
-- assertion above passes just as happily on a meter that recharges at 1ms per
-- ms -- a THREE-second refill -- because the cap at `capacityMs` catches the
-- overshoot and hands back a full meter either way. Only a reading taken PART
-- WAY through the refill can tell the two apart: at three seconds an empty
-- meter is half full, not full and not three-quarters.
local mid = run(0.0, 3000, false)
ok(near(mid, C.capacityMs * 0.5, 1.0),
   'and is only half full at three seconds -- the rate, not just the ceiling',
   mid)
local qtr = run(0.0, 1500, false)
ok(near(qtr, C.capacityMs * 0.25, 1.0),
   'and a quarter full at one and a half', qtr)

-- AND HALF A METER TAKES HALF THAT, which is the property that makes a partial
-- spend cost proportionally rather than costing a full cycle.
local half = run(C.capacityMs * 0.5, 3000, false)
ok(near(half, C.capacityMs, 1.0), 'three seconds refills a half meter', half)

ok(near(S.rechargeRate(4000, 6000), 2 / 3), 'the rate is capacity over recharge')
ok(S.rechargeRate(4000, 0) == 0.0, 'a zero recharge is no rate, not infinity')
ok(S.rechargeRate(0, 6000) == 0.0, 'and a zero capacity earns nothing')

-- NEVER ABOVE FULL, however long nobody boosts.
local over = run(C.capacityMs, 60000, false)
ok(over == C.capacityMs, 'the meter never climbs past full', over)

-- ═══ A FRAME EITHER SPENDS OR EARNS, NEVER BOTH ═══
--
-- If a boosting frame also earned, the meter would drain at (1 - rate) and four
-- seconds of held key would last twelve. That is the mutation this catches.
local one, oneSpent = S.step(C.capacityMs, 100, true, C.capacityMs, C.rechargeMs)
ok(near(one, C.capacityMs - 100), 'a boosting frame only spends', one)
ok(near(oneSpent, 100), 'and reports what it spent', oneSpent)

-- ═══ PARTIAL SPEND ═══
--
--   "Use of partial boost should be acceptable as well, if not fully
--    recharged."
--
-- A meter with 1500ms in it, held indefinitely, spends 1500ms and stops. There
-- is no threshold below which the boost is refused.
local pLeft, pSpent = run(1500.0, 4000, true)
ok(pSpent == 1500.0, 'a part-charged meter spends exactly what it has', pSpent)
ok(pLeft == 0.0, 'and ends empty', pLeft)

-- AND THE RAMP IS NOT RESCALED TO FIT IT. 1500ms of a 2000ms ramp is 75% of the
-- way up, and the boost simply ends there. A "compressed ramp" implementation
-- would reach 1.0 and fail this.
ok(near(S.ramp(pSpent, C.rampMs), 0.75),
   'and gets three quarters of the ramp, not a compressed whole one')

-- THE LAST FRAME OF A PARTIAL SPEND IS SHORT, not refused. 10ms left, a 16ms
-- frame: it spends the 10 and reports it.
local tLeft, tSpent = S.step(10.0, 16, true, C.capacityMs, C.rechargeMs)
ok(tLeft == 0.0 and tSpent == 10.0,
   'the last frame spends what remains rather than nothing', tSpent)

-- DEGENERATE INPUTS.
ok(select(2, S.step(1000, 0, true, C.capacityMs, C.rechargeMs)) == 0.0,
   'a zero-length frame spends nothing')
ok(select(2, S.step(1000, -50, true, C.capacityMs, C.rechargeMs)) == 0.0,
   'and a negative one is no information, not a rewind')
ok(S.step(0 / 0, 16, false, C.capacityMs, C.rechargeMs) >= 0.0,
   'a NaN meter is clamped rather than kept')
ok(S.step(99999, 16, false, C.capacityMs, C.rechargeMs) <= C.capacityMs,
   'and an over-full one is clamped down')

-- ═══ `1` IS NOT `true`, AND `0` IS TRUTHY ═══
--
-- The `boosting` flag arrives from a chain that starts at a FiveM BOOL native.
-- This project has shipped that confusion four times, so the solver tests
-- `== true` and this is the assertion that pins it.
ok(select(2, S.step(1000, 100, 1, C.capacityMs, C.rechargeMs)) == 0.0,
   'a numeric 1 does not spend -- only a real boolean true does')
ok(select(2, S.step(1000, 100, 0, C.capacityMs, C.rechargeMs)) == 0.0,
   'and a numeric 0 certainly does not, however truthy Lua thinks it is')

-- ---------------------------------------------------------------------------
describe('nothing slows the car down')
-- ---------------------------------------------------------------------------
--
--   "Upon releasing or running out of boost, no action against the vehicle
--    should be taken to slow it down or anything."
--
-- ASSERTED AS AN ABSENCE, WHICH IS THE ONLY WAY A PURE MODULE CAN ASSERT IT.
-- The solver has no decay, no restore and no damping function, and this is the
-- test that fails the day somebody adds one to "tidy up" the end of a boost.
local allowed = {
    MPH = true, rechargeRate = true, step = true, ramp = true,
    target = true, fuelMultiplier = true, claimable = true,
}
for k in pairs(S) do
    ok(allowed[k] == true,
       'BR.BoostSolve exposes only what the spec asks for', 'unexpected: ' .. k)
end

-- AND THE TARGET NEVER FALLS BELOW THE BASE, at any point in the curve, so
-- there is no elapsed time at which the arithmetic asks for a slowdown.
local worst = math.huge
for ms = 0, 6000, 50 do
    local t = S.target(25.0, C.addMps, ms, C.rampMs)
    if t - 25.0 < worst then worst = t - 25.0 end
end
ok(worst >= 0.0, 'the target is never below the speed at the press', worst)

-- ---------------------------------------------------------------------------
describe('the fuel surcharge')
-- ---------------------------------------------------------------------------

local M = C.fuelMultiplier

ok(S.fuelMultiplier(0, 250, M) == 1.0, 'an interval with no boost costs 1.0x')
ok(near(S.fuelMultiplier(250, 250, M), M),
   'an interval entirely boosted costs the full 1.5x')
ok(near(S.fuelMultiplier(125, 250, M), 1.25),
   'and half an interval costs half the surcharge')

-- ═══ THE CLAMP IS THE SECURITY BOUND, NOT A TIDY-UP ═══
--
-- `boostedMs` originates on the client by the owner's decision. Whatever
-- arrives, the answer has to land in [1, mult] -- so the worst a liar can do is
-- burn LESS than they should, never negative, never a refill, never a skew.
ok(near(S.fuelMultiplier(99999, 250, M), M),
   'a wildly over-stated claim is still only 1.5x')
ok(S.fuelMultiplier(-500, 250, M) == 1.0,
   'a negative claim is 1.0x, not a discount')
ok(S.fuelMultiplier(0 / 0, 250, M) == 1.0, 'and a NaN claim is 1.0x')
ok(S.fuelMultiplier(125, 0, M) == 1.0, 'a zero interval charges nothing extra')
ok(S.fuelMultiplier(125, -250, M) == 1.0, 'and so does a negative one')
ok(S.fuelMultiplier(250, 250, 0.5) == 1.0,
   'a multiplier below one is read as no surcharge, never as a discount')

-- IT IS A MULTIPLIER ON METRES, so it composes with the ledger by multiplication
-- and nothing else. 100 metres boosted throughout costs 150.
ok(near(100.0 * S.fuelMultiplier(250, 250, M), 150.0),
   'a hundred boosted metres are charged as a hundred and fifty')

-- ---------------------------------------------------------------------------
describe('the claim ceiling')
-- ---------------------------------------------------------------------------
--
-- The server believes the client about boosting -- the owner's call -- but not
-- without bound. BR.BoostSolve.claimable holds a ceiling that refills at the
-- spec's own rate, so a client claiming to boost forever converges on the duty
-- cycle the spec actually permits.

-- A HONEST CLAIM INSIDE A FULL CREDIT IS BELIEVED WHOLE.
local a, credit = S.claimable(C.capacityMs, 250, 250, C.capacityMs, C.rechargeMs)
ok(a == 250.0, 'a full interval of boost on a full credit is believed', a)
ok(near(credit, C.capacityMs - 250.0), 'and costs the credit that much', credit)

-- A CLAIM LONGER THAN THE INTERVAL IS CUT TO THE INTERVAL. There is no way to
-- claim more boosting than wall clock elapsed.
ok(select(1, S.claimable(C.capacityMs, 250, 99999,
                         C.capacityMs, C.rechargeMs)) == 250.0,
   'a claim longer than the interval is cut to the interval')

-- NEGATIVES AND NaNs BECOME ZERO, never a credit.
ok(select(1, S.claimable(C.capacityMs, 250, -1000,
                         C.capacityMs, C.rechargeMs)) == 0.0,
   'a negative claim is believed as nothing')
ok(select(1, S.claimable(C.capacityMs, 250, 0 / 0,
                         C.capacityMs, C.rechargeMs)) == 0.0,
   'and so is a NaN')

-- ═══ A BURST IS STILL THE FULL FOUR SECONDS ═══
--
-- The ceiling must not make an honest boost cheaper than it is. Starting full,
-- sixteen 250ms intervals of continuous claim must all be believed.
local cr, total = C.capacityMs, 0.0
for _ = 1, 16 do
    local got
    got, cr = S.claimable(cr, 250, 250, C.capacityMs, C.rechargeMs)
    total = total + got
end
ok(near(total, 4000.0), 'a burst of four seconds is believed in full', total)

-- ═══ AND SUSTAINED LYING CONVERGES ON FORTY PER CENT ═══
--
-- 4000ms of boost per 6000ms of recharge is a 40% duty cycle: a = dt*r/(1+r)
-- with r = 2/3. A client that claims to be boosting every interval forever is
-- charged for four seconds in every ten, which is exactly what the spec permits
-- -- so the surcharge goes on meaning something even against a liar.
local c2 = C.capacityMs
for _ = 1, 400 do   -- 100 seconds of continuous claim
    _, c2 = S.claimable(c2, 250, 250, C.capacityMs, C.rechargeMs)
end
local steady = 0.0
for _ = 1, 40 do    -- measure over the next ten seconds
    local got
    got, c2 = S.claimable(c2, 250, 250, C.capacityMs, C.rechargeMs)
    steady = steady + got
end
ok(near(steady, 4000.0, 30.0),
   'sustained continuous claims settle at four seconds in every ten', steady)

-- ═══ AND REFILLING HAPPENS ON THE IDLE PART OF THE INTERVAL, NOT ALL OF IT ═══
--
-- Crediting the whole interval and then spending out of the credit would lift
-- the steady state to two thirds. This is the assertion that separates the two:
-- an interval fully spent earns nothing back.
local spentAll, afterAll = S.claimable(1000, 250, 250, C.capacityMs, C.rechargeMs)
ok(spentAll == 250.0 and near(afterAll, 750.0),
   'an interval fully claimed earns no credit back', afterAll)
-- ...and an interval not claimed at all earns the whole rate.
local _, afterIdle = S.claimable(1000, 250, 0, C.capacityMs, C.rechargeMs)
ok(near(afterIdle, 1000.0 + 250.0 * (2 / 3)),
   'an idle interval earns the full rate', afterIdle)

-- THE CREDIT IS BOUNDED BOTH WAYS.
local _, cHigh = S.claimable(C.capacityMs, 10000, 0, C.capacityMs, C.rechargeMs)
ok(cHigh == C.capacityMs, 'the credit never climbs past a full meter', cHigh)
local _, cLow = S.claimable(0, 250, 250, C.capacityMs, C.rechargeMs)
ok(cLow >= 0.0, 'and never goes negative', cLow)
ok(select(1, S.claimable(0, 250, 250, C.capacityMs, C.rechargeMs)) == 0.0,
   'a spent credit believes nothing until it has refilled')
ok(select(1, S.claimable(1000, 0, 250, C.capacityMs, C.rechargeMs)) == 0.0,
   'a zero-length interval believes nothing')

-- ---------------------------------------------------------------------------
describe('the whole boost, end to end')
-- ---------------------------------------------------------------------------
--
-- One held key, sixty frames a second, from full to empty -- reading the target
-- at each frame the way client/boost.lua does. This is the shape of the feature
-- rather than any one function in it.

local base = 20.0
local elapsed, meter = 0, C.capacityMs
local reachedFull, peak = nil, 0.0
while meter > 0.0 do
    local before = meter
    meter = S.step(meter, 16, true, C.capacityMs, C.rechargeMs)
    if meter == before then break end
    local t = S.target(base, C.addMps, elapsed, C.rampMs)
    if t > peak then peak = t end
    if reachedFull == nil and near(t, base + C.addMps, 0.01) then
        reachedFull = elapsed
    end
    elapsed = elapsed + 16
end

ok(near(elapsed, 4000, 20), 'the boost runs for four seconds', elapsed)
ok(reachedFull ~= nil and near(reachedFull, 2000, 20),
   'and is at full speed after two of them', reachedFull)
ok(near(peak, base + C.addMps, 0.01),
   'and never asks for more than base + 30 mph', peak)
ok(elapsed - (reachedFull or 0) >= 1900,
   'so roughly half the boost is spent holding the higher speed',
   elapsed - (reachedFull or 0))

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
