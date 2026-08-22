-- Vehicle boost arithmetic, with no engine in it.
--
-- The client owns the push and the flames (br_core/client/boost.lua) and the
-- server owns the fuel surcharge (br_core/server/fuel.lua). Neither can be unit
-- tested without a running FXServer. This can, which is the same bargain
-- storm_solve.lua, combat_solve.lua and fuel_solve.lua strike, and the reason
-- they exist as separate files rather than as locals inside their consumers.
--
-- ═══ THE SPEC, VERBATIM, BECAUSE EVERY CLAUSE IS A CONSTRAINT ═══
--
--   "we need a vehicle boost. The vehicle boost will be akin to sprint on
--    foot, where while holding SHIFT by default (remappable), and in the
--    driver's seat, the vehicle has flames which come out the back of the
--    tailpipes and is accelerated forward to reach a speed 30mph faster than
--    what it was doing when they pressed it. Boost should last a total of 4
--    seconds and recharge over 6 seconds. Upon releasing or running out of
--    boost, no action against the vehicle should be taken to slow it down or
--    anything. The acceleration should be over the course of the first 2
--    seconds of the boost. Use of partial boost should be acceptable as well,
--    if not fully recharged. Infinite uses are possible."
--                                            -- owner, 2026-08-22, #203
--
-- ═══ THE TARGET IS RELATIVE AND IT IS SAMPLED ONCE ═══
--
-- "30mph faster than what it was doing WHEN THEY PRESSED IT". The base speed is
-- read on the press and then frozen for the whole boost; it is not re-read per
-- frame. Re-reading it would make the target chase the car, so every frame's
-- push would raise the next frame's target and the boost would be an
-- accelerator with no ceiling. `target()` therefore takes `baseMps` as an
-- argument rather than reading anything.
--
-- ═══ THE RAMP IS ELAPSED TIME, NOT BUDGET SPENT ═══
--
-- The two are the same thing for a full boost and differ for a partial one, and
-- the difference is the whole of "use of partial boost should be acceptable".
-- A player with 1.5 seconds in the meter spends 1.5 seconds, which is 75% of
-- the way up a 2-second ramp, and then the boost simply stops. They get a
-- smaller push for a shorter time. They do NOT get a 2-second ramp compressed
-- into 1.5 seconds, and they do not get refused for being under a threshold --
-- there is no minimum here, deliberately, because the spec names none.
--
-- ═══ NOTHING IN THIS FILE ENDS A BOOST BY SLOWING ANYTHING ═══
--
-- "Upon releasing or running out of boost, no action against the vehicle should
-- be taken to slow it down or anything." There is no decay function here, no
-- restore-previous-speed, no damping term, and there must never be one. The
-- only thing that happens at the end of a boost is that `target()` stops being
-- called. The car keeps whatever velocity physics left it holding.

BR = BR or {}

BR.BoostSolve = {}

--- Metres per second in one mile per hour. The spec is written in mph and every
--- native in the game is in m/s, so the conversion happens exactly once.
BR.BoostSolve.MPH = 0.44704

--- A number, or a fallback -- NaN included.
---
--- SEPARATE FROM BR.Clamp FOR THE REASON fuel_solve.clamp IS: `0/0` is a number
--- in Lua, it compares false to everything including itself, so `if v < lo` and
--- `if v > hi` both answer false for it and a NaN walks straight through a
--- clamp. Here it would reach SET_VEHICLE_FORWARD_SPEED, and a NaN velocity is
--- how a vehicle ends up at the origin of the map with no way to explain it.
--- @param v any
--- @param dflt number
--- @return number
local function num(v, dflt)
    v = tonumber(v)
    -- v ~= v is the NaN test. It is the only one Lua has.
    if v == nil or v ~= v then return dflt end
    return v
end

--- Clamp into [lo, hi], NaN-safe.
--- @param v any
--- @param lo number
--- @param hi number
--- @return number
local function clamp(v, lo, hi)
    v = num(v, lo)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Milliseconds of budget earned per millisecond of wall clock while idle.
---
--- A FULL METER TAKES `rechargeMs` TO REFILL FROM EMPTY, which is what "recharge
--- over 6 seconds" means, so the rate is capacity/recharge rather than 1. With
--- the shipped numbers that is 4000/6000 = 0.667 -- two thirds of a second of
--- boost earned per second of not boosting.
--- @param capacityMs number
--- @param rechargeMs number
--- @return number
function BR.BoostSolve.rechargeRate(capacityMs, rechargeMs)
    local cap = num(capacityMs, 0.0)
    local rec = num(rechargeMs, 0.0)
    -- A ZERO OR NEGATIVE RECHARGE WOULD BE AN INFINITE RATE, and infinity times
    -- a zero dt is a NaN in the very next multiplication. Answer zero: a meter
    -- that never refills is a feature switched off, which is recoverable, and a
    -- NaN budget is not.
    if cap <= 0.0 or rec <= 0.0 then return 0.0 end
    return cap / rec
end

--- Advance the meter by one frame.
---
--- ═══ SPENDING AND EARNING ARE EXCLUSIVE, AND THAT IS NOT AN OPTIMISATION ═══
---
--- A frame either spends or earns, never both. Letting a boosting frame also
--- earn would make the effective boost longer than four seconds -- the meter
--- would drain at (1 - rate) rather than at 1 -- and four seconds is a number
--- the owner gave.
---
--- ═══ THE SPEND IS CAPPED BY WHAT IS THERE, WHICH IS HOW A PARTIAL BOOST ENDS
---     ═══
---
--- `spentMs` comes back so the caller can tell a frame that boosted from a frame
--- that could not. A budget of 30ms asked for a 33ms frame spends 30 and returns
--- 30; the caller sees the meter is now empty and ends the boost. Nothing else
--- is needed to implement "running out of boost", and in particular nothing here
--- touches the vehicle.
---
--- @param budgetMs number    milliseconds of boost currently banked
--- @param dtMs number        milliseconds since the last call
--- @param boosting boolean   is the player spending this frame
--- @param capacityMs number  a full meter
--- @param rechargeMs number  empty to full, in milliseconds
--- @return number budget     the new meter
--- @return number spent      milliseconds actually spent this frame, >= 0
function BR.BoostSolve.step(budgetMs, dtMs, boosting, capacityMs, rechargeMs)
    local cap = num(capacityMs, 0.0)
    if cap < 0.0 then cap = 0.0 end

    local budget = clamp(budgetMs, 0.0, cap)
    -- A NEGATIVE OR ABSENT INTERVAL IS NO INFORMATION, not a rewind. The loop
    -- registry hands a callback dt = 0 on its first pass, and a stalled tick can
    -- produce two calls in the same millisecond.
    --
    -- `<=` RATHER THAN `<` IS AN EARLY RETURN, NOT A BEHAVIOUR. Mutation testing
    -- flagged it: at dt exactly 0 the two branches below both answer
    -- (budget, 0.0) anyway -- nothing is spent and nothing is earned -- so a
    -- mutant weakening this to `<` survives, correctly. It stays as `<=` because
    -- "a zero interval is no information" is the rule being stated, and stating
    -- it here is cheaper than leaving it as a consequence of two other branches
    -- both happening to be identities.
    local dt = num(dtMs, 0.0)
    if dt <= 0.0 then return budget, 0.0 end

    -- `boosting == true` RATHER THAN `if boosting`, because this argument
    -- arrives from a chain that begins at a FiveM BOOL native, and in Lua `0` is
    -- truthy. This project has shipped that bug four times.
    if boosting == true then
        local spent = dt
        if spent > budget then spent = budget end
        return budget - spent, spent
    end

    local gained = dt * BR.BoostSolve.rechargeRate(cap, rechargeMs)
    budget = budget + gained
    if budget > cap then budget = cap end
    return budget, 0.0
end

--- How far up the ramp a boost is, 0..1.
---
--- LINEAR, like every other interpolation in this project (see BR.Lerp's note in
--- geo.lua). A smoothstep here would make the first half-second feel like
--- nothing happened, and the one thing a boost has to do is answer the key.
---
--- A ZERO OR NEGATIVE RAMP IS FULLY UP IMMEDIATELY. That is a configuration
--- saying "no ramp", and the alternative -- dividing by it -- is an infinity.
--- @param elapsedMs number  milliseconds since this boost began
--- @param rampMs number
--- @return number  0..1
function BR.BoostSolve.ramp(elapsedMs, rampMs)
    local ramp = num(rampMs, 0.0)
    if ramp <= 0.0 then return 1.0 end
    return clamp(num(elapsedMs, 0.0) / ramp, 0.0, 1.0)
end

--- The speed this boost is currently asking the vehicle to reach, in m/s.
---
--- @param baseMps number   speed at the instant of the press -- frozen, see header
--- @param addMps number    the whole boost, e.g. 30 mph in m/s
--- @param elapsedMs number milliseconds since this boost began
--- @param rampMs number
--- @return number mps
function BR.BoostSolve.target(baseMps, addMps, elapsedMs, rampMs)
    local base = num(baseMps, 0.0)
    if base < 0.0 then base = 0.0 end
    local add = num(addMps, 0.0)
    if add < 0.0 then add = 0.0 end
    return base + add * BR.BoostSolve.ramp(elapsedMs, rampMs)
end

--- The fuel surcharge for a sample interval, as a multiplier on metres.
---
--- ═══ PROPORTIONAL, BECAUSE THE SAMPLE IS 4 Hz AND A BOOST IS 4 SECONDS ═══
---
---   "And yes, boosting should burn fuel faster. Good point. Let's make it burn
---    50% faster while boosting"      -- owner, 2026-08-22
---
--- The fuel ledger charges a vehicle for the ground it covered between two
--- position samples. A boost does not begin and end on those boundaries, so a
--- flat 1.5x on any interval containing any boost would overcharge, and a flat
--- 1.0x unless the whole interval was boosted would undercharge. Charging the
--- fraction of the interval that was boosted is the only version that is right
--- at both ends, and it costs one multiply.
---
--- ═══ THE ANSWER IS ALWAYS IN [1, mult], AND THAT IS THE SECURITY BOUND ═══
---
--- `boostedMs` originates on the CLIENT (see the trust note in
--- br_core/server/fuel.lua). Clamping the fraction into 0..1 here is what makes
--- the worst a liar can do "I burned less than I should have". It can never
--- become a negative charge, a refill, or a multiplier that skews the ledger --
--- whatever number arrives, including a NaN or a negative one.
---
--- @param boostedMs number   milliseconds of this interval spent boosting
--- @param intervalMs number  milliseconds the interval covered
--- @param mult number        the surcharge at 100% boosted, e.g. 1.5
--- @return number  1.0 .. mult
function BR.BoostSolve.fuelMultiplier(boostedMs, intervalMs, mult)
    local m = num(mult, 1.0)
    -- A MULTIPLIER BELOW ONE WOULD MAKE BOOSTING CHEAPER THAN CRUISING. That is
    -- a config typo rather than an attack, and the safe reading of it is "no
    -- surcharge" rather than "a discount".
    if m < 1.0 then m = 1.0 end

    local interval = num(intervalMs, 0.0)
    if interval <= 0.0 then return 1.0 end

    local frac = clamp(num(boostedMs, 0.0) / interval, 0.0, 1.0)
    return 1.0 + (m - 1.0) * frac
end

--- How much of a client's claimed boost time the server is willing to believe.
---
--- ═══ A CEILING, NOT AN AUTHORITY ═══
---
--- This does not decide whether the player boosts -- the client does, instantly,
--- because a twitch input cannot wait for a round trip. It decides only how much
--- boost the FUEL LEDGER will be charged for, and the owner has explicitly
--- accepted the client's word there (see br_core/server/fuel.lua's trust note).
---
--- What it removes is the unbounded shape of that concession. Without it, a
--- client is trusted to say "I boosted for the whole interval" forever, and the
--- surcharge stops describing anything. With it, sustained claims converge on
--- the duty cycle the spec actually permits: with 4000ms of boost recharging
--- over 6000ms, the steady state is
---
---     a = dt * r / (1 + r),  r = 4000/6000  ->  a = 0.4 * dt
---
--- forty per cent of wall clock, which is exactly 4 seconds of boost in every 10.
--- A burst can still be the full four seconds, because the credit starts full.
---
--- ═══ EARNING IS THE PART OF THE INTERVAL THAT WAS NOT SPENT ═══
---
--- Refilling for the whole interval and then spending out of the refill would
--- let a claim be paid for twice and lift the steady state to two thirds. The
--- credit earns on `dt - allowed`, which is the same exclusivity `step()` above
--- applies to the real meter, for the same reason.
---
--- @param creditMs number    the server's running ceiling for this vehicle
--- @param dtMs number        milliseconds since the last charge
--- @param claimedMs number   what the client's reports add up to for this interval
--- @param capacityMs number
--- @param rechargeMs number
--- @return number allowedMs  believed boost time, 0 .. dtMs
--- @return number creditMs   the new ceiling
function BR.BoostSolve.claimable(creditMs, dtMs, claimedMs, capacityMs, rechargeMs)
    local cap = num(capacityMs, 0.0)
    if cap < 0.0 then cap = 0.0 end

    local credit = clamp(creditMs, 0.0, cap)
    local dt = num(dtMs, 0.0)
    if dt <= 0.0 then return 0.0, credit end

    local allowed = clamp(claimedMs, 0.0, dt)
    if allowed > credit then allowed = credit end

    local idle = dt - allowed
    credit = credit - allowed + idle * BR.BoostSolve.rechargeRate(cap, rechargeMs)

    -- ═══ THE FLOOR IS BRACES, AND MUTATION TESTING SAYS SO OUT LOUD ═══
    --
    -- Removing this line changes NOTHING today, and that is worth writing down
    -- rather than leaving for the next person to rediscover. `allowed` is capped
    -- at `credit` four lines up and the recharge term is non-negative, so
    -- `credit - allowed + idle * rate` cannot be negative -- the guard is
    -- unreachable and a mutant that deletes it survives the suite.
    --
    -- KEPT ANYWAY, for the same reason server/fuel.lua keeps its `charged` belt
    -- beside its re-baseline braces: the two protect against different edits.
    -- The cap above is there to bound what a CLIENT may claim; this is there to
    -- bound what the ARITHMETIC may produce. A refactor that reordered the two,
    -- or that let `allowed` be computed somewhere else, would restore a negative
    -- credit -- which is a ceiling that pays out more than a full meter on the
    -- next call. One comparison is cheaper than finding that out.
    if credit < 0.0 then credit = 0.0 end
    if credit > cap then credit = cap end

    return allowed, credit
end
