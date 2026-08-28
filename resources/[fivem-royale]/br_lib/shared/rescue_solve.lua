-- Where the ambulance goes, and how long it is allowed to take (#191).
--
-- PURE. No natives, no state, no clock of its own -- every input arrives as an
-- argument, so tools/test_rescue.lua can drive the whole destination decision
-- outside the game, including the storm-prediction case that is otherwise only
-- reachable by waiting several minutes into a real match.
--
-- The two questions this file answers are the two #191 states as requirements:
--
--   * "Spawns at a preset point chosen for PROXIMITY TO THE DEATH LOCATION."
--   * "Destination chosen from a preset list, preferring a point that WILL BE
--      INSIDE THE STORM CIRCLE BY THE TIME THE AMBULANCE ARRIVES. Where several
--      qualify, TAKE THE SHORTEST ROUTE."
--
-- The second is the interesting one, and the word doing the work is WILL BE.
-- Choosing against the circle as it stands right now is the obvious
-- implementation and it is wrong in the exact case the feature exists for: the
-- storm is usually SHRINKING while the ambulance drives, so a point comfortably
-- inside the wall at dispatch can be well outside it on arrival, and the rescue
-- would deliver a player straight into the damage it just exempted them from.
-- So the destination test is run against the circle SOLVED FORWARD to the
-- estimated arrival time, which is what BR.StormAt already does for every other
-- consumer -- it is a pure function of a published record and a timestamp, and
-- a timestamp in the future is as valid an input as one in the present.

BR = BR or {}

--- How long a drive of this length should take, in ms.
---
--- STRAIGHT LINE TIMES A FUDGE, NOT A ROUTE QUERY, and that is forced rather
--- than lazy. Road distance can only be asked of the engine, from a client, for
--- a point pair that is streamed in -- and this decision is made on the SERVER,
--- for two points that are typically kilometres apart and nowhere near anybody.
--- config/map.lua's Roads block records the same constraint for loot filler.
---
--- The consequence is honest and worth stating: this over-estimates on a
--- motorway and under-estimates through a hillside. `etaSlack` is what covers
--- the second case, and the deadline it produces is a BACKSTOP rather than a
--- schedule -- nothing is shown to the player, and a rescue that arrives early
--- simply ends early.
---
--- @param distM number   straight-line metres
--- @param cfg table|nil   BR.Config.Rescue
--- @return number ms      the drive estimate, unslacked
function BR.RescueDriveMs(distM, cfg)
    cfg = cfg or {}
    local speed = cfg.etaSpeed or 13.0
    if speed <= 0 then speed = 13.0 end
    local road = (distM or 0.0) * (cfg.etaRouteFactor or 1.35)
    return (road / speed) * 1000.0
end

--- The hard deadline for a rescue over this distance, in ms.
---
--- DERIVED PER ROUTE AND CLAMPED AT BOTH ENDS. #191 is explicit that a constant
--- fails a long route; the floor is the other half of that and is just as
--- necessary, because a pickup that happens to be 40 metres from its drop-off
--- would otherwise produce a deadline shorter than the fade-in.
--- @param distM number
--- @param cfg table|nil
--- @return number ms
function BR.RescueDeadlineMs(distM, cfg)
    cfg = cfg or {}
    local floor = cfg.etaFloorMs or 20000
    local drive = BR.RescueDriveMs(distM, cfg)
    local ms = BR.Clamp(drive * (cfg.etaSlack or 1.8), floor, cfg.etaCeilMs or 300000)

    -- ═══ THE CEILING MAY NEVER UNDER-CUT THE DRIVE ITSELF ═══
    --
    -- Caught by tools/test_rescue.lua before this ever ran in a match, and it is
    -- the exact failure #191 warned about wearing a different hat: "a long route
    -- fails a short timer". The clamp was written to stop an absurd deadline,
    -- but on a genuinely map-crossing route it capped the deadline BELOW the
    -- estimated drive -- so the rescue would have been judged out of time while
    -- the ambulance was still driving normally, and (having moved) delivered
    -- early, somewhere short of the destination.
    --
    -- The ceiling is therefore a bound on the SLACK, not on the journey. A route
    -- whose own estimate exceeds it gets that estimate plus a grace instead,
    -- which keeps the guarantee this function actually owes its caller: THE
    -- DEADLINE IS ALWAYS LONGER THAN THE DRIVE IT WAS DERIVED FROM.
    if ms < drive then ms = drive + floor end
    return ms
end

--- The nearest point to a position.
---
--- The pickup end of #191, and deliberately the plainest possible reading of
--- "chosen for proximity to the death location" -- there is no storm term here,
--- because the ambulance is coming TO the player and the player is already
--- wherever they are.
---
--- RETURNS THE DISTANCE TOO, because every caller needs it: the pickup distance
--- is what the arrival estimate for the FIRST leg is built from.
--- @param points table[]  { { x, y, ... }, ... }
--- @param x number
--- @param y number
--- @return table|nil point
--- @return number distance  metres; math.huge when there are no points
function BR.RescueNearest(points, x, y)
    local best, bestD = nil, math.huge
    for _, p in ipairs(points or {}) do
        local d = BR.Dist(x, y, p.x, p.y)
        if d < bestD then best, bestD = p, d end
    end
    return best, bestD
end

--- Choose where to take this player.
---
--- ═══ THE ORDER OF THE TWO RULES IS THE WHOLE DESIGN ═══
---
--- "Preferring a point that will be inside the storm circle when the ambulance
--- arrives; shortest route among qualifying." PREFERRING, then SHORTEST -- so
--- this is a filter followed by a minimum, and NOT a score that trades one
--- against the other. A weighted score would happily pick a slightly-closer
--- point just outside the wall over a slightly-further one just inside it,
--- which is the single outcome the rule exists to forbid.
---
--- ═══ EVERY POINT IS TIMED SEPARATELY, AND IT HAS TO BE ═══
---
--- The arrival time depends on WHICH point is being considered -- a far one is
--- reached later, by which time the circle is smaller. So the qualifying test
--- cannot be run once against one predicted circle; it is run per candidate,
--- against the circle solved for THAT candidate's own arrival. A single shared
--- prediction would systematically over-qualify distant points, which are
--- exactly the ones most likely to be outside the wall on arrival.
---
--- ═══ WHAT HAPPENS WHEN NOTHING QUALIFIES ═══
---
--- It is a normal case, not an error: late in a match the circle can be smaller
--- than the gaps between authored points, and it is entirely possible that no
--- point on the list is inside it. Delivering the player somewhere is still much
--- better than the alternatives -- refusing the rescue after the kit has been
--- spent, or driving to a point in the middle of the wall -- so the fallback is
--- the point CLOSEST TO THE PREDICTED CENTRE, which is the least-bad drop
--- available and puts them pointed the right way with their health back.
--- `inside` is returned so the caller can log which of the two happened; nothing
--- is shown to the player either way.
---
--- @param points table[]        candidate drop-offs
--- @param fromX number          where the ambulance starts
--- @param fromY number
--- @param storm table|nil       the published storm record, or nil
--- @param now number            server ms
--- @param cfg table|nil         BR.Config.Rescue
--- @return table|nil point
--- @return number distance      metres from the start
--- @return boolean inside       true if the chosen point qualified
--- `exclude` IS THE PICKUP, AND WITHOUT IT THE RESCUE DRIVES NOWHERE.
---
--- Owner, 2026-08-28, on the first ride that actually ran: "It drove for maybe
--- 30 seconds successfully, but then de-spawned and put me back at the point
--- where it spawned."
---
--- The pickup is one of the same surveyed points this loop chooses from, and
--- its distance from itself is ZERO -- so `d < bestD` always picked it and the
--- destination was the place the ambulance had just been built. It then drove a
--- circle until the deadline (floored at etaFloorMs, hence ~30s) and delivered
--- the player back where they started, with a success toast, having gone
--- nowhere. Every layer above worked perfectly; the route was zero-length.
function BR.RescueDestination(points, fromX, fromY, storm, now, cfg, exclude)
    local best, bestD = nil, math.huge          -- best QUALIFYING
    local fall, fallD = nil, math.huge          -- best by distance-to-centre

    -- A point closer than this is the pickup by another name -- two surveyed
    -- car parks in the same forecourt would produce the same non-journey.
    local minTrip = (cfg and cfg.minTripM) or 150.0

    for _, p in ipairs(points or {}) do
        local d = BR.Dist(fromX, fromY, p.x, p.y)
        if (exclude and p == exclude) or d < minTrip then goto continue end

        -- This candidate's own arrival, and the circle as it will be then.
        local eta = now + BR.RescueDriveMs(d, cfg)
        local cx, cy, r = BR.StormAt(storm, eta)

        -- NO RECORD MEANS NO CONSTRAINT. Before the first circle is published
        -- there is nothing to be inside of, BR.StormAt answers a zero circle,
        -- and treating that as "nothing qualifies" would send every pre-storm
        -- rescue to the fallback for no reason. A zero radius is the tell.
        if not storm or r <= 0.0 then
            if d < bestD then best, bestD = p, d end
        else
            if BR.InCircle(p.x, p.y, cx, cy, r) then
                if d < bestD then best, bestD = p, d end
            end
            local dc = BR.Dist(p.x, p.y, cx, cy)
            if dc < fallD then fall, fallD = p, dc end
        end
        ::continue::
    end

    if best then
        return best, bestD, true
    end
    if fall then
        return fall, BR.Dist(fromX, fromY, fall.x, fall.y), false
    end
    return nil, math.huge, false
end

--- Has the ambulance made progress since the last judgement?
---
--- THE SERVER'S OWN QUESTION, ASKED OF THE SERVER'S OWN SAMPLES. A rescue in
--- flight is judged on where the server last observed the player's ped, never on
--- anything the client says about the vehicle -- see server/rescue.lua for why
--- the two halves of "stuck versus destroyed" are split by who observes them.
---
--- Pure so the threshold is testable: the interesting cases are a vehicle
--- creeping along at just under the bar and a position sample that has not been
--- refreshed at all, and neither is convenient to produce in game.
---
--- @param prev table|nil   { x, y } the position at the last judgement
--- @param pos table|nil    { x, y } now
--- @param cfg table|nil
--- @return boolean moved
function BR.RescueMoved(prev, pos, cfg)
    if not prev or not pos then return false end
    return BR.Dist(prev.x, prev.y, pos.x, pos.y) >= ((cfg or {}).progressM or 8.0)
end
