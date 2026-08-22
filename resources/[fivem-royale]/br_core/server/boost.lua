-- Vehicle boost, server half: the relay and the fuel surcharge.
--
-- This file does NOT decide whether anybody boosts. The client does, instantly,
-- because a twitch input cannot wait for a round trip -- br_core/client/boost.lua
-- owns the meter, the push and the flames. What lives here is the two things a
-- client cannot do for itself:
--
--   1. TELL EVERY OTHER SCREEN, so the flames appear on more than one machine.
--      The record published is small and dumb: a network id, and when the boost
--      is due to end in SERVER TIME. Every client draws its own local particle
--      effect from that -- see client/boost.lua's header on why a ptfx is not an
--      entity and `sv_entityLockdown relaxed` has nothing to refuse.
--   2. ANSWER "WAS THIS VEHICLE BOOSTING" for server/fuel.lua's sample pass, so
--      the 1.5x surcharge can be applied to a ledger the client does not own.
--
-- ═══ THE TRUST BOUNDARY, AND IT IS CROSSED HERE ON PURPOSE ═══
--
-- Fuel is server-authoritative by design. server/fuel.lua charges a vehicle for
-- displacement IT measures between the roster's own position samples, precisely
-- so a client cannot decide how much fuel it has spent, and this repo has a
-- documented history of regretting client-authored fields -- GetPedSourceOfDeath
-- was rejected for kill attribution on exactly these grounds.
--
-- BOOST IS AN EXCEPTION, AND IT IS THE OWNER'S CALL, VERBATIM:
--
--   "We can break the rules for once and let the client decide how much fuel is
--    burned for the boost. That's a non-impacting thing if it were to be
--    abused."                                        -- owner, 2026-08-22
--
-- WHAT AN ATTACKER GAINS, STATED PLAINLY: a client that boosts without reporting
-- it burns fuel at 1.0x instead of 1.5x. It still pays for every metre it
-- covered -- the ledger measures the ground, not the throttle -- so the whole
-- theft is the 0.5x surcharge on the distance covered during a boost. At the
-- shipped numbers that is at most about 80 metres of a 6000-metre tank per full
-- four-second boost: roughly one and a third per cent of a tank, and it cannot
-- be spent any faster than the recharge allows.
--
-- WHAT AN ATTACKER CANNOT GAIN, AND THIS IS THE PART THAT IS BOUNDED RATHER THAN
-- TRUSTED. The concession is "the client may under-report", not "the client may
-- say anything":
--
--   * the claim is EDGES, NOT DURATIONS. A client says "starting" and "stopping";
--     the elapsed time is measured HERE, off this server's own clock. There is no
--     field carrying a number of milliseconds for anyone to inflate.
--   * BR.BoostSolve.fuelMultiplier clamps the boosted FRACTION into 0..1 and the
--     multiplier into [1, mult], so no claim can produce a negative charge, a
--     refill, or a multiplier outside the band -- whatever arrives, including a
--     NaN.
--   * BR.BoostSolve.claimable holds a per-vehicle CEILING that refills at the
--     spec's own rate, so a client claiming to boost continuously is believed for
--     four seconds and then converges on forty per cent of wall clock, which is
--     exactly the duty cycle 4s-of-boost-per-6s-of-recharge permits. It is a
--     ceiling on the CHARGE and never gates the boost itself.
--
-- So the exposure is "burned less than I should have", by a bounded amount,
-- which is the shape the owner signed off on. It is not a general "the client
-- writes the fuel ledger", and it must not be cited as precedent for one.

BR = BR or {}
BR.Boost = {}

local C = BR.Config and BR.Config.Boost

-- THERE IS NO `didHit` IN THIS FILE, and its absence is deliberate rather than
-- an omission. Every neighbouring server file carries one, because a FiveM native
-- declared BOOL hands Lua a number on some builds and a boolean on others and IN
-- LUA `0` IS TRUTHY -- the bug this project has shipped four times. Nothing here
-- reads a BOOL native: the only natives called are GetVehiclePedIsIn,
-- NetworkGetNetworkIdFromEntity and GetPedInVehicleSeat, all of which return
-- handles or ids, and all three are compared to explicit values rather than
-- tested for truth. An unused normaliser sitting here would read as coverage this
-- file does not need.

--- Is the boost switched on at all?
--- @return boolean
local function enabled()
    return C ~= nil and C.enabled == true and (tonumber(C.capacityMs) or 0) > 0
end

--- Which player states may boost. The same pair server/fuel.lua gates on: a
--- lobby ped and a corpse are outside any match, and a spectator is watching
--- somebody else's car.
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

--- Natives this file needs, checked once rather than assumed.
---
--- Almost nothing about a vehicle is answerable on the server -- config/
--- vehicles.lua makes the same point about GetVehicleClass, which has no server
--- handler at all -- so the two the driver check leans on are worth asking about.
--- WITHOUT THEM THE RELAY STILL RUNS: the flames are cosmetic, and a server that
--- cannot check who is driving should show the boost rather than refuse it. The
--- fuel surcharge is unaffected either way, because it is the client's word by
--- the owner's decision.
local have = {
    vehiclePedIsIn = type(GetVehiclePedIsIn) == 'function',
    pedInSeat      = type(GetPedInVehicleSeat) == 'function',
    netIdFrom      = type(NetworkGetNetworkIdFromEntity) == 'function',
}

--- Per-vehicle boost bookkeeping. [netId] = { on, since, owed, credit, seen }
---
---   on      is a boost running right now
---   since   server time it started, for the running portion
---   owed    milliseconds already banked for the next fuel charge
---   credit  the ceiling BR.BoostSolve.claimable maintains
---   seen    last time anything touched this row, for the sweep
---
--- KEYED ON THE VEHICLE, NOT THE PLAYER, and that is not a contradiction of the
--- meter being per player. The METER is the driver's -- it follows them between
--- cars, which is what "akin to sprint on foot" means. The CHARGE is the
--- vehicle's, because server/fuel.lua's ledger is per vehicle and the surcharge
--- has to land on the same row as the metres it multiplies. Two different
--- questions, two different keys.
local boosts = {}

--- When each player's last accepted BOOST_SET arrived. [src] = server ms.
---
--- KEYED ON THE PLAYER, unlike `boosts` above, because the thing being rate
--- limited is a sender rather than a car -- the same split server/fuel.lua makes
--- between its per-vehicle `tanks` and its per-player `pumping`.
local lastMsg = {}

--- The floor on the gap between two accepted messages from one player.
local MIN_MSG_MS = 100

local stat = {
    starts = 0, stops = 0, refused = 0, swept = 0, charged = 0, throttled = 0,
}

--- The vehicle a player is sitting in, as a network id, or nil.
--- @param ped integer
--- @return integer|nil
local function vehicleOf(ped)
    if not have.vehiclePedIsIn or not have.netIdFrom then return nil end
    if not ped or ped == 0 then return nil end
    local okv, veh = pcall(GetVehiclePedIsIn, ped, false)
    if not okv or not veh or veh == 0 then return nil end
    local okn, nid = pcall(NetworkGetNetworkIdFromEntity, veh)
    if not okn then return nil end
    nid = math.tointeger(tonumber(nid))
    -- ZERO IS EXPLICIT, and `0` is truthy in Lua: it is what the engine answers
    -- for a vehicle that is not networked.
    if nid == nil or nid == 0 then return nil end
    return nid, veh
end

--- Is this player really the driver of this network id?
---
--- ═══ THE FUEL CHARGE IS THE CLIENT'S WORD; THE RELAY IS NOT ═══
---
--- The owner's decision covers how much fuel a boost burns. It does not extend to
--- letting a client set another player's car on fire, or set fire to a car it is
--- a passenger in, which is a griefing surface rather than a ledger one and costs
--- two natives to close.
--- @param src integer
--- @param netId integer
--- @return boolean
local function isDriverOf(src, netId)
    local e = BR.Roster.get(src)
    if not e or not LIVE[e.state] or e.matchId == nil then return false end

    local ped = e.ped
    if not ped or ped == 0 then return false end

    local mine, veh = vehicleOf(ped)
    if mine == nil or mine ~= netId then return false end

    -- DRIVER'S SEAT ONLY -- the owner's rule, and the client checks it too. This
    -- is the half that decides what is ALLOWED rather than what is drawn.
    if not have.pedInSeat then
        -- A RULE THAT CANNOT BE CHECKED IS A RULE WE DO NOT HAVE. Unlike
        -- refuelling, which refuses outright on such a build, this widens to any
        -- seat: the worst outcome is a passenger's screen drawing flames on a car
        -- that is genuinely theirs, and refusing would mean no boost visuals at
        -- all on a whole class of build.
        return true
    end
    local oks, driver = pcall(GetPedInVehicleSeat, veh, -1)
    return oks and driver == ped
end

--- Fold the currently-running portion of a boost into `owed`, up to `now`.
--- @param rec table
--- @param now number
local function settle(rec, now)
    if not rec.on then return end
    local d = now - rec.since
    if d > 0 then rec.owed = rec.owed + d end
    rec.since = now
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.BOOST_SET)
AddEventHandler(BR.Net.BOOST_SET, function(d)
    local src = source
    if not enabled() then return end
    if type(d) ~= 'table' then return end

    local netId = math.tointeger(tonumber(d.netId))
    if netId == nil or netId == 0 then return end

    local now = GetGameTimer()
    local on = (d.on == true)
    local rec = boosts[netId]

    -- ═══ THE CHEAP CHECKS COME FIRST, AND THE ORDER IS THE WHOLE DEFENCE ═══
    --
    -- This is the only message in the boost feature and an accepted one goes out
    -- to EVERY client. Unthrottled, a modified client costs one driver check
    -- (three natives) and one server-wide broadcast PER PACKET, which is a
    -- two-line amplifier. So everything a table lookup can settle is settled
    -- before anything that touches the engine.
    --
    -- A REPEAT SAYS NOTHING AND COSTS NOTHING. The client sends edges, so a
    -- second "on" while already on is a retry or a liar; neither is worth telling
    -- sixty clients about, because client/boost.lua's flamesOn extends rather
    -- than re-lighting and a duplicate stop puts out flames that are already out.
    if rec ~= nil and on == (rec.on == true) then return end
    -- ...and a stop for a vehicle nobody has ever boosted is the same nothing,
    -- WITHOUT creating a row for it. Otherwise a client could fill this table by
    -- naming network ids at random.
    if rec == nil and not on then return end

    -- ═══ THE THROTTLE APPLIES TO STARTS ONLY, AND THAT ASYMMETRY IS THE POINT
    --     ═══
    --
    -- The failure modes are not symmetric. A START that is dropped costs a boost
    -- its flames on other screens -- cosmetic, and the player still gets the
    -- push. A STOP that is dropped leaves a car ALIGHT on sixty screens until its
    -- deadline expires, which is the one visible failure this feature has. A
    -- player tapping the key faster than 100ms is doing something legitimate --
    -- partial spends, infinite uses -- and must never be the reason a car stays
    -- on fire.
    --
    -- So starts are rate limited and stops are always heard. That is safe because
    -- a stop can only ever be accepted once per start: the state-change check
    -- above has already dropped every stop that follows a stop.
    if on then
        local last = lastMsg[src]
        if last ~= nil and (now - last) < MIN_MSG_MS then
            stat.throttled = stat.throttled + 1
            return
        end
        lastMsg[src] = now
    end

    if not isDriverOf(src, netId) then
        stat.refused = stat.refused + 1
        return
    end

    if rec == nil then
        rec = { on = false, since = now, owed = 0.0,
                credit = tonumber(C.capacityMs) or 0.0, seen = now }
        boosts[netId] = rec
    end
    rec.seen = now

    if on then
        rec.on, rec.since = true, now
        stat.starts = stat.starts + 1

        -- ═══ endsAt IS RE-DERIVED HERE RATHER THAN RELAYED ═══
        --
        -- The client sends one, and it is only a hint about its own meter. What
        -- goes out to every other screen is bounded by the SPEC: a boost cannot
        -- outlast `capacityMs` from the moment it started, whatever a client
        -- claims. Relaying the client's number verbatim would let one client set
        -- a car alight on everybody's screen for as long as it liked -- a
        -- cosmetic exploit, but a free and permanent one, and the fix is a
        -- min() rather than a rule.
        local cap = tonumber(C.capacityMs) or 0.0
        local endsAt = now + cap
        local claimed = tonumber(d.endsAt)
        if claimed ~= nil and claimed == claimed and claimed < endsAt then
            endsAt = claimed
        end

        TriggerClientEvent(BR.Net.BOOST_SYNC, -1,
            { netId = netId, on = true, endsAt = endsAt })
    else
        settle(rec, now)
        rec.on = false
        stat.stops = stat.stops + 1
        TriggerClientEvent(BR.Net.BOOST_SYNC, -1, { netId = netId, on = false })
    end
end)

-- ---------------------------------------------------------------------------
-- What server/fuel.lua asks
-- ---------------------------------------------------------------------------

--- How much of the last `dtMs` this vehicle is believed to have spent boosting.
---
--- CONSUMING: the answer is taken out of the row, so the next interval starts
--- from zero and no millisecond is charged twice. server/fuel.lua calls this
--- exactly once per vehicle per pass, from inside the branch that has already
--- decided this vehicle is being charged at all.
---
--- @param netId integer
--- @param dtMs number   the interval server/fuel.lua measured
--- @return number ms    0 .. dtMs
function BR.Boost.spend(netId, dtMs)
    if not enabled() then return 0.0 end
    netId = math.tointeger(tonumber(netId))
    if netId == nil then return 0.0 end

    local rec = boosts[netId]
    if rec == nil then return 0.0 end

    local now = GetGameTimer()
    settle(rec, now)
    rec.seen = now

    local allowed
    allowed, rec.credit = BR.BoostSolve.claimable(
        rec.credit, dtMs, rec.owed, C.capacityMs, C.rechargeMs)
    -- ONLY WHAT WAS BELIEVED IS CONSUMED. A claim that hit the ceiling leaves the
    -- remainder in `owed`, where the next interval's ceiling can pay for it --
    -- which is what stops a boost that straddles a sample boundary being lost,
    -- without letting a liar bank claims indefinitely (the ceiling still bounds
    -- the total).
    rec.owed = rec.owed - allowed
    if rec.owed < 0.0 or rec.owed ~= rec.owed then rec.owed = 0.0 end
    -- AND IT CANNOT BANK MORE THAN ONE FULL METER. Without this, a client that
    -- claimed continuously for a minute would leave sixty seconds in `owed` and
    -- go on being charged the surcharge long after it stopped.
    local cap = tonumber(C.capacityMs) or 0.0
    if rec.owed > cap then rec.owed = cap end

    if allowed > 0.0 then stat.charged = stat.charged + 1 end
    return allowed
end

--- The multiplier server/fuel.lua should apply to this vehicle's metres.
---
--- The one call site. Kept as a function rather than leaving the two-step to the
--- caller so that "ask the boost model what this interval cost" is one line over
--- there, and so the clamp in BR.BoostSolve.fuelMultiplier can never be skipped.
--- @param netId integer
--- @param dtMs number
--- @return number  1.0 .. BR.Config.Boost.fuelMultiplier
function BR.Boost.fuelMultiplier(netId, dtMs)
    if not enabled() then return 1.0 end
    return BR.BoostSolve.fuelMultiplier(
        BR.Boost.spend(netId, dtMs), dtMs, C.fuelMultiplier)
end

-- THERE IS NO `BR.Boost.forget`, AND THE SHAPE OF ITS ABSENCE IS THE POINT.
--
-- The obvious companion to server/fuel.lua's tank sweep is a hook that drops the
-- matching boost row when a tank is dropped, so the two tables cannot disagree.
-- It was written and then removed: nothing would have called it. fuel.lua deletes
-- from `tanks` in three separate places, so wiring it would mean three edits in a
-- file another change is already touching, to keep two tables in step that do not
-- need to be -- this one expires on its own clock below, and a row that comes
-- back is a row that comes back FULL, which is the state a swept one would have
-- decayed to anyway.
--
-- An uncalled function is worse than a missing one: it reads as a contract
-- somebody is honouring. Add it when something needs it.

--- Counters, for /brboost.
--- @return table
function BR.Boost.stats()
    local live, running = 0, 0
    for _, rec in pairs(boosts) do
        live = live + 1
        if rec.on then running = running + 1 end
    end
    return {
        tracked = live, running = running,
        starts = stat.starts, stops = stat.stops,
        refused = stat.refused, swept = stat.swept, charged = stat.charged,
        throttled = stat.throttled,
    }
end

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------

--- A row nobody has touched for a while is a car nobody is boosting.
---
--- SHORTER THAN THE FUEL TTL ON PURPOSE. server/fuel.lua's idleTtlMs is five
--- minutes because a parked car must still be dry when its driver walks back to
--- it -- that is the feature. A boost row holds at most four seconds of claim and
--- a credit that refills to full in six, so a row nobody has touched for a minute
--- is carrying nothing anybody could want. Dropping it re-creates it full, which
--- is the same state it would have decayed to anyway.
local IDLE_TTL_MS = 60000

BR.Sched.every(15000, 'boost.sweep', function()
    if not enabled() then return end
    local now = GetGameTimer()
    for netId, rec in pairs(boosts) do
        if not rec.on and (now - rec.seen) > IDLE_TTL_MS then
            boosts[netId] = nil
            stat.swept = stat.swept + 1
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    -- ═══ A DRIVER WHO VANISHES MID-BOOST MUST NOT LEAVE A CAR ON FIRE ═══
    --
    -- Their stop message is never coming. The flames go out on every client
    -- anyway, on the deadline the START message already carried -- that is what
    -- `endsAt` is for and it needs nothing from here. What this closes is the
    -- LEDGER side: the running portion is settled so the car is charged for what
    -- it actually burned, and then the boost is off.
    --
    -- WHICH VEHICLE, WITHOUT ASKING THE PED. By the time this fires the ped may
    -- already be gone, so the row is found by walking the (very small) table for
    -- anything still running rather than by resolving a handle that may not
    -- exist. A boost that was not theirs is not running, so there is nothing to
    -- mis-settle.
    lastMsg[src] = nil

    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    local mine = e and e.ped and vehicleOf(e.ped) or nil
    local now = GetGameTimer()
    if mine and boosts[mine] and boosts[mine].on then
        settle(boosts[mine], now)
        boosts[mine].on = false
        stat.stops = stat.stops + 1
        TriggerClientEvent(BR.Net.BOOST_SYNC, -1, { netId = mine, on = false })
    end
end)

--- Everything about the relay, in one paste.
RegisterCommand('brboost', function()
    local s = BR.Boost.stats()
    print('=== boost ===')
    print(('  enabled %s   capacity %sms   recharge %sms   fuel x%s'):format(
        tostring(enabled()), tostring(C and C.capacityMs),
        tostring(C and C.rechargeMs), tostring(C and C.fuelMultiplier)))
    print(('  tracked %d  running %d  starts %d  stops %d')
        :format(s.tracked, s.running, s.starts, s.stops))
    print(('  refused %d  throttled %d  swept %d  charged %d')
        :format(s.refused, s.throttled, s.swept, s.charged))
    print(('  natives: vehiclePedIsIn %s  pedInSeat %s  netIdFrom %s'):format(
        tostring(have.vehiclePedIsIn), tostring(have.pedInSeat),
        tostring(have.netIdFrom)))
end, true)
