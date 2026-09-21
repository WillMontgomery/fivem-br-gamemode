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

-- ═══════════════════════════════════════════════════════════════════════════
-- THE TWO GATES ON THE CAR -- THE REAL CLIENT FILE, DRIVEN THROUGH THE REAL
-- LOOP
--
--   "make the vehicle boost only work if the engine is on and fuel is >=5%"
--                                              -- owner, 2026-09-21
--
-- ═══ WHY THESE CANNOT BE TESTED AS ARITHMETIC, THE WAY EVERYTHING ABOVE IS ═══
--
-- Every assertion above this line is br_lib: a pure function with numbers in and
-- a number out. Neither gate is that. Each one is a POSITION IN A CHAIN, and
-- every property worth pinning is about the position rather than the test:
--
--   * a refusal must end a boost that is ALREADY RUNNING, because both facts can
--     go false mid-burn -- the engine is shot out, or the tank crosses the line;
--   * it must end it through stop(), so the flames go out with the impulse. A
--     stopped boost that keeps its flames gets reported as a different bug;
--   * a refused frame must not CHARGE the meter, or a player leaning on the key
--     in a dead car would empty it for nothing;
--   * ">=" must be ">=". A threshold written as ">" is the classic off-by-one
--     and no pure function in this suite would notice;
--   * and the verdict ladder must name the right one of the two, because "boost
--     does nothing, meter stays at 100" is now ALSO what an empty tank looks
--     like from the driver's seat.
--
-- None of that is visible in a boolean. So this block does what
-- tools/test_vehdamage.lua does for #213: it stubs a world, loads
-- br_core/client/main.lua for the loop registry and then the REAL
-- br_core/client/boost.lua, and steps the FRAME band. The file under test is the
-- shipped one, and the chain it walks is the shipped chain.
--
-- ═══ WHAT THE FIXTURE MODELS, AND WHY EACH PIECE IS THERE ═══
--
--   * IsPedInAnyVehicle AND IsVehicleEngineOn ANSWER NUMBERS, not booleans, and
--     that is deliberate: a native declared BOOL hands Lua `1`/`0` on some
--     builds, `0` is truthy in Lua, and this repository has shipped that
--     confusion seven times. Both shapes are driven below, because a gate
--     written `if not IsVehicleEngineOn(veh)` passes the boolean build and lets
--     every engine-off car boost on the numeric one.
--   * THE IMPULSES ARE RECORDED, not just counted. "The boost stopped" and "the
--     boost kept pushing" are the same meter reading and a different number of
--     pushes, which is the only way to tell a live gate from a press-only one.
--   * THE FLAMES ARE COUNTED TOO, for the reason above: agreement between the
--     three is the requirement, so the test has to be able to see all three.
--   * BR.Fuel.levelPct IS STUBBED, because client/fuel.lua cannot be loaded by a
--     test -- tools/test_fuel.lua says so at length, and nothing has changed. So
--     the claim that matters most here, THAT THE GATE READS THE BAR'S OWN
--     NUMBER, is pinned by the source-text block at the bottom instead. That is
--     the same bargain test_fuel.lua strikes for its own uncoverable rules.

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function RegisterNetEvent() end
function TriggerEvent() end
function AddEventHandler() end
function RegisterCommand() end
function DisableControlAction() end
Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

--- Every BR.Net.BOOST_SET this client sent, in order. The stop announcement is
--- what makes OTHER screens put the flames out, so a gate that ended a boost
--- without one would leave every remote copy alight until the deadline.
local sent = {}
function TriggerServerEvent(name, d) sent[#sent + 1] = { name = name, d = d } end

local VEH, NETID = 42, 900

--- Where the player is and what they are doing.
local myVeh, iAmDriver = VEH, true
local heldKey = false
local carSpeed = 20.0

function PlayerPedId() return 77 end
--- A NUMBER, NOT A BOOLEAN. See the fixture note above.
function IsPedInAnyVehicle() return myVeh ~= 0 and 1 or 0 end
function GetVehiclePedIsIn() return myVeh end
function GetPedInVehicleSeat(_, seat)
    if seat == -1 and iAmDriver then return 77 end
    return 0
end
--- 0 is COMPACT, which is not in BR.Config.Boost.excludeClasses and is not in
--- BR.Config.Boost.enginelessClasses either, so the default car is asked both
--- gates. 13 is CYCLES and is driven below.
local vehClass = 0
function GetVehicleClass() return vehClass end

--- THE ENGINE, IN BOTH SHAPES A BOOL NATIVE ARRIVES IN.
---
--- `engineShape` is the whole reason this stub is not one line. A build that
--- answers `0` for a dead engine and a build that answers `false` are the same
--- fact and opposite Lua truth values, and only one of them catches a bare truth
--- test.
local engineState, engineShape = true, 'number'
function IsVehicleEngineOn()
    if engineShape == 'number' then return engineState and 1 or 0 end
    if engineShape == 'absent' then return nil end
    return engineState
end

--- WHAT client/fuel.lua WOULD ANSWER FOR THE CAR UNDER THE PLAYER.
---
--- nil is not empty: it is "no tank is being modelled for this vehicle", which
--- is the fuel feature switched off or a vehicle that is not networked.
local fuelReading = 100.0
BR.Fuel = {}
function BR.Fuel.levelPct() return fuelReading end

local impulses = {}

--- A CAR THAT ACTUALLY ANSWERS THE IMPULSE, WHICH ONE BLOCK BELOW NEEDS AND THE
--- REST MUST NOT HAVE.
---
--- `bScaleByMass` is what makes the impulse a velocity change in m/s -- see
--- client/boost.lua's header -- so a sandbox car's whole physics model is
--- `speed = speed + dv`. That is enough to measure a CEILING, which is the one
--- property a count of impulses cannot see: a boost that re-samples its base
--- speed and a boost that does not apply the same number of impulses and arrive
--- at different speeds. Off by default, because every other assertion in this
--- file wants a car travelling at a speed it chose.
local integrate = false
function ApplyForceToEntity(_, _, _, y)
    impulses[#impulses + 1] = y
    if integrate then carSpeed = carSpeed + y end
end
function GetEntitySpeedVector() return { x = 0.0, y = carSpeed } end
function GetEntitySpeed() return carSpeed end
function NetworkGetNetworkIdFromEntity() return NETID end

local ptfxOn, ptfxOff = 0, 0
function RequestNamedPtfxAsset() end
function HasNamedPtfxAssetLoaded() return 1 end
function UseParticleFxAsset() end
function GetEntityBoneIndexByName() return 3 end
function StartParticleFxLoopedOnEntityBone()
    ptfxOn = ptfxOn + 1
    return 500 + ptfxOn
end
function StopParticleFxLooped() ptfxOff = ptfxOff + 1 end
function NetworkGetEntityFromNetworkId() return VEH end
function DoesEntityExist() return 1 end

BR.Keys = {
    isHeld   = function(a) return a == 'boost' and heldKey or false end,
    labelFor = function() return 'LSHIFT' end,
}

for _, f in ipairs({
    'br_lib/shared/clock.lua',      -- BR.Clock.now, for the flame deadline
    'br_lib/shared/protocol.lua',   -- BR.Net.BOOST_SET; loaded, never retyped
    'br_core/client/main.lua',      -- the loop registry; must precede the file
    'br_core/client/boost.lua',
}) do load(f) end

local B = BR.Boost

local FRAME_MS = 16

--- Step the FRAME band, which is the band boost.drive is registered on.
local function frames(n)
    for _ = 1, (n or 1) do
        fakeTime = fakeTime + FRAME_MS
        BR.Loop.step(BR.Loop.FRAME)
    end
end

--- Step the TICK band, which is where the flames actually attach. `handles`
--- stays nil until this runs, so a test that wants to see flames go OUT has to
--- let them go on first.
local function tickOnce()
    fakeTime = fakeTime + 100
    BR.Loop.step(BR.Loop.TICK)
end

--- THE FIRST STEP OF A BAND HAS dt 0, because BR.Loop has no previous run to
--- measure from. Burned here so no assertion below is quietly measuring it.
frames(1)

--- Back to a full meter, a live engine, a full tank and a released key.
---
--- ONE SIX-SECOND IDLE FRAME IS A FULL RECHARGE, which is the spec's own number
--- (empty to full in 6000 ms) and is why this needs no access to `budget`. The
--- key is released first, so the dry latch clears on the same frame.
local function reset()
    heldKey = false
    myVeh, iAmDriver = VEH, true
    engineState, engineShape = true, 'number'
    fuelReading = 100.0
    carSpeed = 20.0
    vehClass = 0
    integrate = false
    fakeTime = fakeTime + 6000
    BR.Loop.step(BR.Loop.FRAME)
    B.trace(nil)
    sent, impulses = {}, {}
    ptfxOn, ptfxOff = 0, 0
end

--- Hold the key for `n` frames and say whether the boost ever pushed.
local function holdFor(n)
    heldKey = true
    frames(n or 3)
    return #impulses > 0
end

-- ---------------------------------------------------------------------------
describe('the gates: the harness itself')
-- ---------------------------------------------------------------------------
--
-- ═══ A FIXTURE THAT CANNOT TELL A WORKING BOOST FROM A BROKEN ONE PROVES
--     NOTHING ═══
--
-- docs/testing.md rule 4, and it is the assertion that has to come first: every
-- refusal below is "the boost did not push", which is also what a mis-stubbed
-- world produces. So the control case is stated before any gate is closed.

reset()
ok(holdFor(3) == true,
   'a driver holding the key in a live car with a full tank boosts', #impulses)
ok(B.active() == true, 'and the boost is running while they hold it')
ok(B.meter() < 100.0, 'and the meter is being spent', B.meter())

-- ---------------------------------------------------------------------------
describe('the engine has to be running')
-- ---------------------------------------------------------------------------

reset()
engineState = false
ok(holdFor(3) == false, 'a car coasting with the engine off does not boost',
   #impulses)
ok(B.active() == false, 'and no boost is running')
ok(B.meter() == 100.0,
   'and the meter was not charged for the frames it refused -- a player leaning '
   .. 'on the key in a dead car must not lose their boost', B.meter())

-- ═══ AND THE REFUSAL SURVIVES BOTH SHAPES OF THE BOOL ═══
--
-- `0` IS TRUTHY IN LUA. A gate written `if not IsVehicleEngineOn(veh) then`
-- reads `not 0` as false on a build that answers numbers, concludes the engine
-- is running, and boosts every dead car on that client -- while passing happily
-- on a build that answers `false`. So both are driven, and this project has
-- shipped that exact confusion seven times.
reset()
engineState, engineShape = false, 'number'
ok(holdFor(3) == false, 'a numeric 0 from the native is an engine that is OFF')
reset()
engineState, engineShape = false, 'boolean'
ok(holdFor(3) == false, 'and so is a real `false`')
reset()
engineState, engineShape = true, 'number'
ok(holdFor(3) == true, 'a numeric 1 is an engine that is ON')
reset()
engineState, engineShape = true, 'boolean'
ok(holdFor(3) == true, 'and so is a real `true`')

-- ═══ A BUILD THAT CANNOT ANSWER GETS THE BOOST, NOT A DEAD FEATURE ═══
--
-- An unbound native, a raise, or a nil would otherwise refuse every boost on
-- that client for ever, with exactly the "boost does nothing, meter stays at
-- 100" symptom #203 was. The gate is worth less than the feature.
reset()
local savedEngineNative = IsVehicleEngineOn
IsVehicleEngineOn = nil
ok(holdFor(3) == true,
   'a build with no IsVehicleEngineOn boosts rather than losing the feature')
IsVehicleEngineOn = function() error('unbound native') end
reset()
ok(holdFor(3) == true, 'and so does one where the native raises')
IsVehicleEngineOn = savedEngineNative
reset()
engineShape = 'absent'
ok(holdFor(3) == true, 'and so does one where it answers nothing at all')

-- ---------------------------------------------------------------------------
describe('a vehicle with no engine is not asked whether its engine is on')
-- ---------------------------------------------------------------------------
--
-- ═══ BICYCLES, AND THE UNCONFIRMED NATIVE ANSWER THIS IS WRITTEN AGAINST ═══
--
-- BR.Config.Boost.excludeClasses holds 15 and 16 only, so class 13 -- CYCLES --
-- reaches the gates and is meant to. A bicycle has no ignition, and nobody has
-- established what IS_VEHICLE_ENGINE_ON answers for one: it cannot be established
-- from here, because a real answer needs the game and this fixture stubs the
-- native.
--
-- THE FAIL-OPEN PATH DOES NOT COVER IT, WHICH IS THE WHOLE PROBLEM. `nil` and a
-- raise are already treated as "cannot tell, so boost" -- asserted just above --
-- but a plain `false` is a perfectly good answer that means the engine is off,
-- and every bicycle on the server would lose the boost while /brboostwhy told the
-- rider to start an engine a bicycle does not have. So the ENGINE gate is not
-- applied to a class that has no engine, and which way the native answers stops
-- mattering. Both shapes are driven below for that reason.
reset()
vehClass = 13
engineState, engineShape = false, 'boolean'
ok(holdFor(3) == true,
   'a bicycle boosts even when the native answers a plain `false` for its engine',
   #impulses)
reset()
vehClass = 13
engineState, engineShape = false, 'number'
ok(holdFor(3) == true, 'and when it answers a numeric 0', #impulses)

-- AND THE CARVE-OUT IS EXACTLY THAT NARROW. A car is still a car.
reset()
vehClass = 0
engineState = false
ok(holdFor(3) == false,
   'a COMPACT with its engine off still does not boost -- the carve-out is the '
   .. 'class, not the gate', #impulses)

-- ═══ AND THE FUEL GATE IS UNTOUCHED ON A CYCLE ═══
--
-- The review found the fuel half self-consistent with the gauge, so only the
-- engine half is carved out. A cycle below the line refuses like anything else.
reset()
vehClass = 13
fuelReading = 4.9
ok(holdFor(3) == false, 'a bicycle below the fuel line does not boost', #impulses)
reset()
vehClass = 13
fuelReading = 5.0
ok(holdFor(3) == true, 'and one at exactly the line does', #impulses)

-- ═══ THE CLASS LIST IS THE CONFIG'S, NOT THIS FILE'S ═══
--
-- Asserted by MOVING it, the way the fuel threshold is. A literal 13 buried in
-- the frame callback would pass every assertion above and fail these two.
local shippedEngineless = C.enginelessClasses
C.enginelessClasses = { [0] = true }
reset()
engineState = false
ok(holdFor(3) == true,
   'adding a class to BR.Config.Boost.enginelessClasses exempts it')
reset()
vehClass = 13
engineState = false
ok(holdFor(3) == false,
   'and taking cycles out of it puts the engine gate back on them')
C.enginelessClasses = {}
reset()
vehClass = 13
engineState = false
ok(holdFor(3) == false, 'an empty table is the gate applying to everything again')
C.enginelessClasses = shippedEngineless
ok(C.enginelessClasses[13] == true,
   'and the shipped table exempts cycles, which is class 13')

-- ---------------------------------------------------------------------------
describe('the tank has to have at least five per cent in it')
-- ---------------------------------------------------------------------------

-- ═══ THE BOUNDARY, IN BOTH DIRECTIONS, BECAUSE THE OWNER WROTE ">=" ═══
--
-- A threshold written `>` passes the 4.9 assertion and the 5.1 assertion and
-- fails only this one. It is the single most likely defect in the whole change.
reset()
fuelReading = 5.0
ok(holdFor(3) == true, 'a tank at EXACTLY five per cent boosts -- ">=", not ">"',
   ('%s%% against %s%%'):format(fuelReading, C.minFuelPct))

reset()
fuelReading = 4.9
ok(holdFor(3) == false, 'a tank at four point nine does not', #impulses)
ok(B.meter() == 100.0, 'and is not charged for refusing', B.meter())

reset()
fuelReading = 5.1
ok(holdFor(3) == true, 'and anything above five does')
reset()
fuelReading = 100.0
ok(holdFor(3) == true, 'as does a full one')
reset()
fuelReading = 0.0
ok(holdFor(3) == false, 'and an empty one certainly does not')

-- ═══ THE THRESHOLD IS THE CONFIG'S, NOT THIS FILE'S ═══
--
-- Asserted by MOVING it. A literal 5 buried in the frame callback would pass
-- every assertion above and fail these three, which is the only reason they are
-- here.
reset()
local shippedMin = C.minFuelPct
C.minFuelPct = 40.0
fuelReading = 20.0
ok(holdFor(3) == false, 'raising BR.Config.Boost.minFuelPct raises the gate')
reset()
fuelReading = 45.0
ok(holdFor(3) == true, 'and a tank above the raised line still boosts')
C.minFuelPct = 0.0
reset()
fuelReading = 0.0
ok(holdFor(3) == true, 'and a threshold of zero is a gate that never refuses')
C.minFuelPct = shippedMin

-- ═══ NIL IS NOT EMPTY ═══
--
-- It means no tank is being modelled for this vehicle at all -- the fuel feature
-- switched off, or a vehicle that is not networked, which is the Battle Bus and
-- the one case client/boost.lua already documents as "gets the push and no
-- flames". Refusing there would turn a feature switch into a boost that
-- mysteriously does nothing, which is the whole class of bug #203 was.
reset()
fuelReading = nil
ok(holdFor(3) == true, 'a vehicle with no tank modelled for it still boosts')
reset()
fuelReading = 0 / 0
ok(holdFor(3) == true, 'and a NaN reading is no reading, not an empty tank')

reset()
local savedLevelPct = BR.Fuel.levelPct
BR.Fuel.levelPct = nil
ok(holdFor(3) == true,
   'a build where client/fuel.lua never loaded boosts rather than losing the '
   .. 'feature to a missing reader')
BR.Fuel.levelPct = function() error('boom') end
reset()
ok(holdFor(3) == true, 'and so does one where the reader raises')
BR.Fuel.levelPct = savedLevelPct
reset()
local savedFuel = BR.Fuel
BR.Fuel = nil
ok(holdFor(3) == true, 'and so does one with no BR.Fuel at all')
BR.Fuel = savedFuel

-- ---------------------------------------------------------------------------
describe('a boost already running')
-- ---------------------------------------------------------------------------
--
-- ═══ THE CHOICE, WRITTEN DOWN: IT STOPS THE MOMENT THE CONDITION FAILS ═══
--
-- Both facts can go false under a live boost -- the engine is shot out, or the
-- tank crosses the line mid-burn -- and the alternative was "finish the burn you
-- started". It stops, for the reason every other clause in that chain is already
-- live: the seat, the class, the key and the meter are all re-derived per frame,
-- so a pair of gates that only applied at the press would be the only ones in
-- the file a driver could get behind and stay behind.
--
-- AND THE THREE HAVE TO AGREE. A stopped boost that keeps its flames on is the
-- thing that gets reported as a different bug entirely, so each direction below
-- asserts the impulse, the meter and the flames -- and the stop ANNOUNCEMENT,
-- which is what makes every other screen agree too.

--- Start a boost, let the flames attach, and forget the bookkeeping so what
--- follows is measured from a running boost rather than from the press.
local function midBoost()
    reset()
    heldKey = true
    frames(3)
    tickOnce()              -- the flames attach on the TICK band
    local litNow = ptfxOn
    impulses, sent = {}, {}
    ptfxOff = 0
    return litNow
end

local litA = midBoost()
ok(B.active() == true, 'the fixture reaches a running boost')
ok(litA > 0, 'with flames actually attached to the car', litA)

-- THE CONTROL, AND IT COMES FIRST. Every assertion below is "the boost stopped",
-- which is also what running out of meter looks like -- so the same three frames
-- with nothing touched must show a boost that is still going.
frames(3)
ok(B.active() == true and #impulses > 0,
   'a boost nobody interferes with is still pushing three frames later',
   #impulses)
ok(ptfxOff == 0, 'and its flames are still lit')

-- ── THE ENGINE DIES MID-BURN ───────────────────────────────────────────────
midBoost()
engineState = false
frames(1)
ok(B.active() == false, 'an engine shot out mid-boost ends the boost')
ok(#impulses == 0, 'and nothing is pushed on that frame or after it', #impulses)
ok(ptfxOff > 0, 'and the flames go out with it -- not one without the other',
   ptfxOff)
ok(#sent == 1 and sent[1].d.on == false,
   'and the stop is announced, so every other screen douses its own copy',
   #sent)
local meterAfterEngine = B.meter()
frames(10)
ok(B.meter() >= meterAfterEngine,
   'and the meter recharges from there rather than draining under a held key',
   ('%.1f -> %.1f'):format(meterAfterEngine, B.meter()))

-- ── ...AND IT DOES NOT COME BACK UNDER THE SAME HELD KEY ───────────────────
--
-- ═══ THIS ASSERTION USED TO SAY THE OPPOSITE, AND THAT WAS A DECISION RATHER
--     THAN COVERAGE ═══
--
-- It read "the engine coming back resumes it under the same held key", and
-- checked only that SOME impulse happened. Both halves were wrong, and the
-- second half is why the first survived review.
--
-- A RESUMED BOOST IS A BOOST WITH NO CEILING. The press path samples the base
-- speed once and freezes it, precisely so the target cannot chase the car -- its
-- own comment says "the boost would have no ceiling at all" otherwise. A gate
-- that stops a live boost and then lets it restart under the same hold runs that
-- press path a second time, and it re-samples the base off the speed the first
-- half of the boost had already delivered. Measured on the shipped file from
-- 20.0 m/s, against a +30 mph spec: a steady burn reached +13.41 m/s, one
-- 1-frame engine cut reached +20.71 m/s (+46 mph), and a 1-frame cut every 40
-- frames reached +25.43 m/s (+57 mph). Nothing bounded it, and an engine that
-- flickers or a tank riding the 5 percent line is enough to ask for it.
--
-- SO A GATE STOP LATCHES, AND `gated` IS A SIBLING OF `dry` RATHER THAN A SECOND
-- USE OF IT: "the meter emptied" and "the car stopped qualifying" want different
-- answers out of /brboostwhy, so they are different flags with a rung each.
midBoost()
engineState = false
frames(1)
ok(B.active() == false, 'the engine going off stops it')
engineState = true
impulses = {}
frames(5)
ok(B.active() == false and #impulses == 0,
   'and the engine coming back does NOT resume it under the same held key -- a '
   .. 'resumed boost re-samples its base speed and has no ceiling',
   #impulses)

-- AND A FRESH PRESS IS ALL IT COSTS, which is the same bargain the dry latch
-- strikes. The meter still has most of four seconds in it, so this is not the
-- recharge being waited for -- it is the release clearing the latch.
heldKey = false
frames(1)
heldKey = true
frames(3)
ok(B.active() == true and #impulses > 0,
   'and a release and a fresh press boosts again straight away', #impulses)

-- ═══ THE CEILING ITSELF, AS A NUMBER ═══
--
-- The assertion above is a count, and a count is exactly what let the old rule
-- through: "some impulse happened" is true of a resumed boost and of a legal one
-- alike. This block gives the sandbox car a physics model -- an impulse scaled by
-- mass IS a velocity change, so `speed = speed + dv` -- and asserts the only
-- thing that separates them, which is where the car ends up.

local BASE = 20.0

--- Hold the key for `n` frames from `BASE` m/s and return the best gain over it.
--- `cut` is asked for each frame number and turns the engine off for that frame.
local function peakGain(n, cut)
    reset()
    integrate = true
    carSpeed = BASE
    heldKey = true
    local best = 0.0
    for i = 1, n do
        engineState = not (cut and cut(i))
        frames(1)
        local g = carSpeed - BASE
        if g > best then best = g end
    end
    integrate = false
    return best
end

-- THE CONTROL FIRST, AND IT IS ALSO THE SPEC. Four seconds of clean burn from
-- 20 m/s arrives at exactly +30 mph and not a fraction more, which is both the
-- baseline every assertion below is measured against and the proof that the
-- sandbox car can reach the number at all.
local steadyGain = peakGain(250)
ok(near(steadyGain, C.addMps, 0.05),
   'a clean four-second burn gains exactly the +30 mph the spec asks for',
   ('%.2f m/s against %.2f'):format(steadyGain, C.addMps))

-- ONE INTERRUPTION MUST NOT RAISE THE CEILING. Without the latch this measured
-- +20.71 m/s, which is +46 mph out of a feature specified at +30.
local oneCutGain = peakGain(250, function(i) return i == 70 end)
ok(oneCutGain <= steadyGain + 0.05,
   'a boost a gate interrupted never ends up faster than one it did not',
   ('one cut %.2f m/s against a steady %.2f'):format(oneCutGain, steadyGain))

-- AND NEITHER MAY MANY. Without the latch this measured +25.43 m/s, +57 mph, and
-- every further interruption raised it again -- there was no bound at all.
local flickerGain = peakGain(250, function(i) return i % 40 == 0 end)
ok(flickerGain <= steadyGain + 0.05,
   'and a repeatedly interrupted one does not climb with each interruption',
   ('flickering %.2f m/s against a steady %.2f'):format(flickerGain, steadyGain))

-- ═══ AND THE FLICKER IS NOT A STUTTER EITHER ═══
--
-- The same alternation used to produce 0 impulses over 20 frames -- each restart
-- began the ramp at zero, asked for nothing on its first frame and was stopped on
-- the next -- while the meter drained from 100 to 88.4. It also sent 10
-- BOOST_SET on and 10 off in those 20 frames, and the server throttles starts
-- only, so every accepted edge is a broadcast to every other client; locally it
-- started and stopped 170 particle effects. That is `dry`'s own note, verbatim:
-- "a held key producing an endless stutter of ramp-restarts and no acceleration
-- at all".
midBoost()
local meterBeforeFlicker = B.meter()
sent, impulses = {}, {}
ptfxOn, ptfxOff = 0, 0
for i = 1, 20 do
    engineState = (i % 2 == 0)
    frames(1)
    tickOnce()              -- the flames attach here, so a strobe is visible
end
local starts, stops = 0, 0
for _, m in ipairs(sent) do
    if m.d.on == true then starts = starts + 1 else stops = stops + 1 end
end
ok(starts == 0 and stops == 1,
   'a flickering engine sends ONE stop to the relay and no further starts',
   ('%d on, %d off'):format(starts, stops))
ok(ptfxOn == 0, 'and lights no more flames, so nothing strobes', ptfxOn)
ok(B.meter() >= meterBeforeFlicker,
   'and the meter recharges through it rather than draining for no acceleration',
   ('%.1f -> %.1f'):format(meterBeforeFlicker, B.meter()))

-- ── THE TANK CROSSES THE LINE MID-BURN ─────────────────────────────────────
midBoost()
fuelReading = 4.9
frames(1)
ok(B.active() == false, 'a tank crossing below five per cent ends the boost')
ok(#impulses == 0, 'and nothing is pushed after it', #impulses)
ok(ptfxOff > 0, 'and the flames go out with it', ptfxOff)
ok(#sent == 1 and sent[1].d.on == false, 'and the stop is announced', #sent)

-- AND EXACTLY FIVE PER CENT DOES NOT, which is the boundary again -- this time
-- against a boost that is already running, where a `>` would cut a live burn.
midBoost()
fuelReading = 5.0
frames(2)
ok(B.active() == true and #impulses > 0,
   'a tank sitting at exactly five per cent does not interrupt a live boost',
   #impulses)

-- ---------------------------------------------------------------------------
describe('the verdict ladder')
-- ---------------------------------------------------------------------------
--
-- ═══ TWO SILENT REFUSALS WOULD COST A PLAYTEST ROUND ═══
--
-- "Boost does nothing, meter stays at 100" is now ALSO what an empty tank looks
-- like from the driver's seat, and what a stalled engine looks like. Each wants
-- a fix in a different place -- one is a petrol station, one is the ignition,
-- one is a bug -- so each gets a rung.
--
-- DRIVEN BOTH WAYS. The synthetic tables below pin the ORDER and the guards,
-- which is the part that can be got wrong without any counter being missing; the
-- end-to-end block after them pins that the counters and facts those rungs read
-- are actually written by the shipped frame callback.

--- A window in which the key was seen and the player was driving a boostable
--- car, and nothing was boosted. Every rung above rung 3 has already passed.
local function window(extra)
    local f = {
        enabled = true, frames = 100, heldFrames = 100,
        inVehFrames = 100, driverFrames = 100, wantFrames = 0,
        minFuelPct = 5.0,
    }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

local code = B.verdict(window({ engineOffFrames = 100 }))
ok(code == 'engine-off', 'an engine that was off for the window is engine-off',
   code)
code = B.verdict(window({ lowFuelFrames = 100, fuelPctMin = 3.0 }))
ok(code == 'fuel-low', 'and a tank below the line is fuel-low', code)

-- ═══ NEITHER FIRES FOR THE OTHER ONE'S CAUSE ═══
--
-- This is the assertion the whole ladder exists for. A rung that answered for a
-- cause it did not measure would send the next round to the wrong file, which
-- costs exactly the playtest round /brboostwhy was built to save.
ok(B.verdict(window({ engineOffFrames = 100 })) ~= 'fuel-low',
   'an engine fault is never reported as a fuel fault')
ok(B.verdict(window({ lowFuelFrames = 100, fuelPctMin = 3.0 })) ~= 'engine-off',
   'and a fuel fault is never reported as an engine fault')

-- ═══ AND WHEN BOTH ARE TRUE THE TANK WINS, WHICH IS WHY THE CHAIN ASKS IT
--     FIRST ═══
--
-- A dry tank STALLS the car: client/fuel.lua writes a zero level and GTA's own
-- fuel system cuts the engine, which is that file's whole reason for existing.
-- So an empty car trips BOTH counters, and 'engine-off' would send that player
-- to start an engine that cannot start.
code = B.verdict(window({ lowFuelFrames = 100, fuelPctMin = 0.0,
                          engineOffFrames = 100 }))
ok(code == 'fuel-low',
   'an empty tank that stalled the engine is reported as the tank, not the '
   .. 'stall -- the cause, not its consequence', code)

-- ═══ AND THE THIRD RUNG, WHICH IS THE ONE THE GATES THEMSELVES MADE NECESSARY
--     ═══
--
-- The two rungs above are about a boost that NEVER STARTED, which is what their
-- `wantFrames == 0` guard says. A gate that stops a LIVE boost is the opposite
-- case and cannot be reached through that guard: a live boost means at least one
-- frame wanted it. So the failure mode the gates introduced was the one case the
-- ladder could not name, and it came out as `already-ahead` -- the car was going
-- faster than a ramp that had just restarted at zero, which is true and is not
-- the cause, and which sends the next round to APPLY_FORCE_TO_ENTITY.
code = B.verdict(window({ gateStops = 3, gateLatch = true, wantFrames = 40,
                          pushFrames = 40, engineOffFrames = 12 }))
ok(code == 'gate-tripped',
   'a gate that stopped a live boost is gate-tripped, with wantFrames above zero',
   code)

-- AND IT IS GUARDED ON THE LATCH STILL BEING SET, NOT ON THE COUNT. A driver who
-- stalled, let go and then boosted properly has a stop count and no latch, and
-- must not be told the stall was the answer -- which is the guard the class rung
-- makes the same argument for.
code = B.verdict(window({ gateStops = 3, gateLatch = false, wantFrames = 40,
                          pushFrames = 40, forced = 40, engineOffFrames = 12,
                          addMps = 13.4112, gain = 13.0 }))
ok(code == 'ok',
   'a gate that stopped a boost the driver then re-pressed and finished is ok',
   code)

-- AND IT DOES NOT STEAL THE NEVER-STARTED CASES FROM THE TWO RUNGS ABOVE IT. A
-- car that was never running has no live boost for a gate to stop.
code = B.verdict(window({ engineOffFrames = 100, gateLatch = false }))
ok(code == 'engine-off',
   'an engine that was off for the whole window is still engine-off', code)
code = B.verdict(window({ lowFuelFrames = 100, fuelPctMin = 3.0,
                          gateLatch = false }))
ok(code == 'fuel-low', 'and a tank below the line is still fuel-low', code)

-- ═══ NEITHER RUNG FIRES FOR A DRIVER WHO THEN BOOSTED PROPERLY ═══
--
-- The class rung's own guard, for the class rung's own reason: a player who
-- stalled for a moment, or coasted the last of a tank onto a forecourt and
-- filled up, and then boosted must not be told that was the answer.
code = B.verdict(window({ engineOffFrames = 20, lowFuelFrames = 20,
                          fuelPctMin = 1.0, wantFrames = 80, pushFrames = 80,
                          forced = 80, addMps = 13.4112, gain = 13.0 }))
ok(code == 'ok',
   'a window that stalled, ran dry, recovered and then boosted comes out ok',
   code)

-- AND THE RUNGS STAY OUT OF THE WAY OF THE ONES BELOW THEM. A car that was
-- running, fuelled, and simply had no meter is still the meter's answer.
code = B.verdict(window({ emptyFrames = 100 }))
ok(code == 'meter-empty',
   'a live, fuelled car with an empty meter is still meter-empty', code)

-- ═══ EACH SENTENCE NAMES WHAT TO CHECK AND WHERE ═══
--
-- A readout that prints numbers and leaves the reading to the person holding the
-- controller is what costs the round. These are the words that make the next
-- step a place rather than a guess.
local _, fuelSaid = B.verdict(window({ lowFuelFrames = 100, fuelPctMin = 3.0 }))
ok(fuelSaid:find('minFuelPct', 1, true) ~= nil,
   'the fuel rung names the config knob', fuelSaid)
ok(fuelSaid:find('BR.Fuel.levelPct', 1, true) ~= nil,
   'and the reading it used, so a bar that disagrees convicts the reading',
   fuelSaid)
ok(fuelSaid:find('3.0', 1, true) ~= nil and fuelSaid:find('5.0', 1, true) ~= nil,
   'and prints the number it saw beside the number it wanted', fuelSaid)
local _, engSaid = B.verdict(window({ engineOffFrames = 100 }))
ok(engSaid:find('IS_VEHICLE_ENGINE_ON', 1, true) ~= nil,
   'the engine rung names the native it read', engSaid)
ok(engSaid:find('boost.lua', 1, true) ~= nil,
   'and the file to look in when the car is running on screen', engSaid)

-- AND THE GATE RUNG NAMES THE ACTION, because "let go and press again" is the
-- whole answer and a readout that only described the state would leave the player
-- holding a key that can no longer work.
local _, gateSaid = B.verdict(window({ gateStops = 2, gateLatch = true,
                                       wantFrames = 40, pushFrames = 40,
                                       engineOffFrames = 9, lowFuelFrames = 4 }))
ok(gateSaid:find('press again', 1, true) ~= nil,
   'the gate rung tells the player to release and press again', gateSaid)
ok(gateSaid:find('9', 1, true) ~= nil and gateSaid:find('4', 1, true) ~= nil,
   'and prints which of the two gates tripped and how often', gateSaid)

-- ═══ END TO END: THE SHIPPED CALLBACK FILLS WHAT THE RUNGS READ ═══
--
-- The synthetic tables above would pass just as happily against a frame callback
-- that never wrote a single one of those counters. Mutation testing on
-- client/debug.lua's own `rawSelf` found exactly that gap once -- a whole verdict
-- unreachable because nothing ever wrote the field it read -- so the counters
-- are driven through the real file here.

--- Arm a trace, hold the key through a refusal, and read the verdict out of the
--- real counters plus the real facts, exactly as /brboostwhy does.
local function verdictOf(setup)
    reset()
    local t = {}
    B.trace(t)
    setup()
    heldKey = true
    frames(10)
    B.trace(nil)
    for k, v in pairs(B.facts()) do t[k] = v end
    return B.verdict(t), t
end

local liveCode, liveTrace = verdictOf(function() engineState = false end)
ok(liveCode == 'engine-off',
   'a real window of engine-off frames reads out as engine-off', liveCode)
ok((liveTrace.engineOffFrames or 0) > 0,
   'because the frame callback counted them', liveTrace.engineOffFrames)

liveCode, liveTrace = verdictOf(function() fuelReading = 3.0 end)
ok(liveCode == 'fuel-low',
   'and a real window of low-fuel frames reads out as fuel-low', liveCode)
ok((liveTrace.lowFuelFrames or 0) > 0,
   'because the frame callback counted them', liveTrace.lowFuelFrames)
ok(near(liveTrace.fuelPctMin, 3.0),
   'and carried the lowest reading it saw, so the sentence can print it',
   liveTrace.fuelPctMin)
ok(near(liveTrace.minFuelPct, C.minFuelPct),
   'and BR.Boost.facts() carries the threshold from the config',
   liveTrace.minFuelPct)

-- AND A GATE THAT IS NOT BEING ENFORCED SAYS SO. A build with no
-- IsVehicleEngineOn passes every car, which is the right trade and is also
-- invisible without this counter.
savedEngineNative = IsVehicleEngineOn
IsVehicleEngineOn = nil
local _, unreadable = verdictOf(function() end)
ok((unreadable.engineUnreadable or 0) > 0,
   'a build that cannot read the engine counts every frame it could not ask',
   unreadable.engineUnreadable)
IsVehicleEngineOn = savedEngineNative

local _, noTank = verdictOf(function() fuelReading = nil end)
ok((noTank.fuelUnknown or 0) > 0,
   'and a vehicle with no tank modelled counts those frames too',
   noTank.fuelUnknown)

-- ═══ AND THE FLICKER, THROUGH THE REAL CALLBACK, READS OUT AS THE GATE ═══
--
-- This is the case the synthetic tables above cannot vouch for, and it is the one
-- that was wrong: the shipped loop has to write `gateStops` and `gateLatch`, and
-- the flicker has to stop coming out as `already-ahead`, which named the impulse
-- for something the gates did.
reset()
local flickTrace = {}
B.trace(flickTrace)
heldKey = true
for i = 1, 20 do
    engineState = (i % 2 == 1)
    frames(1)
end
B.trace(nil)
for k, v in pairs(B.facts()) do flickTrace[k] = v end
local flickCode = B.verdict(flickTrace)
ok(flickCode == 'gate-tripped',
   'a real flickering engine reads out as gate-tripped', flickCode)
ok(flickCode ~= 'already-ahead',
   'and never as already-ahead, which would blame the impulse for a gate')
ok((flickTrace.gateStops or 0) > 0,
   'because the frame callback counted the stop', flickTrace.gateStops)
ok((flickTrace.gatedFrames or 0) > 0,
   'and counted the frames it refused afterwards', flickTrace.gatedFrames)
ok(flickTrace.gateLatch == true,
   'and BR.Boost.facts() says the latch is still set under this hold',
   tostring(flickTrace.gateLatch))
ok((flickTrace.wantFrames or 0) > 0,
   'with wantFrames above zero, which is why the two rungs above it cannot '
   .. 'reach this case', flickTrace.wantFrames)

-- AND A BICYCLE IS NEVER TOLD TO START ITS ENGINE. The engine gate is not applied
-- to a class that has no engine, so the counter the engine rung reads is never
-- written for one and the rung cannot fire.
local cycleCode, cycleTrace = verdictOf(function()
    vehClass = 13
    engineState, engineShape = false, 'boolean'
end)
ok(cycleCode ~= 'engine-off',
   'a bicycle is never told to start an engine it does not have', cycleCode)
ok((cycleTrace.engineOffFrames or 0) == 0,
   'because no frame counted an engine-off for it',
   cycleTrace.engineOffFrames)
ok((cycleTrace.enginelessFrames or 0) > 0,
   'and the frames that skipped the gate say so in the readout',
   cycleTrace.enginelessFrames)

-- ---------------------------------------------------------------------------
describe('one fuel reading, not two')
-- ---------------------------------------------------------------------------
--
-- ═══ THE CLAIM THIS SUITE CANNOT EXECUTE, PINNED BY GREP INSTEAD ═══
--
-- client/fuel.lua cannot be loaded by a test -- tools/test_fuel.lua makes that
-- argument at length and nothing has changed -- so the fuel reading above is a
-- stub, and a stub agrees with any implementation. The property it therefore
-- cannot check is the most important one in the change:
--
--   A BOOST THAT REFUSES WHILE THE BAR SAYS 40 PER CENT, because it read a
--   different number, IS A WORSE BUG THAN THE ONE THE GATE FIXES.
--
-- So the two files are read as TEXT and the single-reading property is asserted
-- on the source: the gate reads BR.Fuel.levelPct and nothing else, and the bar
-- and BR.Fuel.levelPct are the same expression called twice.

local function source(path)
    local fh = io.open(ROOT .. path, 'r')
    if not fh then return '' end
    local s = fh:read('a')
    fh:close()
    return s
end

local boostSrc = source('br_core/client/boost.lua')
local fuelSrc  = source('br_core/client/fuel.lua')

ok(boostSrc ~= '' and fuelSrc ~= '', 'both client files were readable')

ok(boostSrc:find('BR.Fuel and BR.Fuel.levelPct', 1, true) ~= nil,
   'the boost gate reads the fuel level through BR.Fuel.levelPct')
-- A CALL, NOT A MENTION. Both files NAME GetVehicleFuelLevel in prose, because
-- it was the obvious reach and the reason it is wrong -- litres of a per-model
-- tank rather than a fraction of one -- is worth writing down where the next
-- person will look for it. So the assertion has to ask whether it is CALLED.
ok(boostSrc:find('GetVehicleFuelLevel%s*%(') == nil
   and boostSrc:find('pcall%(%s*GetVehicleFuelLevel') == nil,
   'and never reads the engine\'s own litre count, which is a different number '
   .. 'in a different unit and is not what the bar draws')
ok(boostSrc:find('C.minFuelPct', 1, true) ~= nil,
   'and takes its threshold from the config rather than from a literal')
ok(boostSrc:find('return pct >= minPct', 1, true) ~= nil,
   'and compares it with ">=", which is the owner\'s word')

ok(fuelSrc:find('function BR.Fuel.levelPct', 1, true) ~= nil,
   'client/fuel.lua exports the reading the gate asks for')
ok(fuelSrc:find('local function pctOf', 1, true) ~= nil,
   'and the fraction-to-percentage conversion is one function')
ok(fuelSrc:find('fuel = math.floor(pctOf(', 1, true) ~= nil,
   'the vitals bar is that function rounded to a whole percent')
ok(fuelSrc:find('return pctOf(', 1, true) ~= nil,
   'and BR.Fuel.levelPct is that same function unrounded -- one expression, '
   .. 'called twice, so the gauge and the gate cannot describe two tanks')

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
