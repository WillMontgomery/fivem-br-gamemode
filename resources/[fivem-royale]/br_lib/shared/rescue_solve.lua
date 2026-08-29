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
--
-- ═══ AND SINCE 2026-08-28 IT IS RUN AGAINST THE PURPLE CIRCLE TOO ═══
--
-- Owner: "the destination was not inside the PURPLE storm circle, and it should
-- have been. If no destinations are available within the PURPLE storm circle -
-- then cprkits are not available for use."
--
-- Solving StormAt forward is NOT the same question. Through a hold -- which is
-- most of a phase -- the circle at any arrival time inside it is the CURRENT
-- one, so a destination could qualify against the wall the player is already
-- standing in while sitting well outside the one they can see drawn ahead of
-- them. BR.RescueCircles asks both, and the second one is read straight off the
-- record's cx1/cy1/r1 exactly as shared/airdrop_solve.lua reads it.
--
-- THE OTHER HALF OF HIS SENTENCE IS A REFUSAL, and it replaces a fallback: there
-- is no longer a "nearest to the centre" consolation drop. Nothing qualifying
-- means no rescue, no ambulance, and -- checked rather than assumed -- no kit
-- spent. See BR.RescueDestination.
--
-- ═══ ...AND THE THIRD QUESTION: WHEN IS THE RIDE OVER ═══
--
-- BR.RescueArrived. It used to be eight metres from the surveyed point, which a
-- road-routed vehicle heading for a car park never reaches, so every ride was
-- resolved by the deadline instead. It is now the owner's own design -- arrive,
-- or park as close as it got -- and it is here rather than in the client for the
-- same reason the destination rule is: it is arithmetic, and the case worth
-- testing (a vehicle circling a point it cannot reach) is expensive to stage.

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
--- schedule -- a rescue that arrives early simply ends early.
---
--- AND THE PLAYER NOW SEES THAT BACKSTOP (owner, 2026-08-28: "let's add an
--- on-screen timer showing their time to revive please"). This comment used to
--- end "nothing is shown to the player", which is no longer true and is exactly
--- the sort of stale claim that gets believed. What is drawn is the DEADLINE,
--- not this estimate -- and reading it as "time to revive" is correct rather
--- than a simplification, because server/rescue.lua DELIVERS a moving ambulance
--- when the deadline lands (`if rec.everMoved then finish(src, true, ...)`).
--- The countdown is therefore an upper bound on the wait, and beating it is the
--- normal case: `etaSlack` is 1.8, so a drive that goes to plan ends with a
--- little under half the clock still on it.
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

--- The circles a destination has to be inside, for an ambulance arriving at
--- `eta`.
---
--- ═══ TWO CIRCLES, AND THE SECOND ONE IS THE OWNER'S ═══
---
--- Owner, 2026-08-28, on a ride that delivered him outside the wall he could
--- see: "the destination was not inside the PURPLE storm circle, and it should
--- have been."
---
--- THE PURPLE CIRCLE IS `cx1, cy1, r1` -- the circle the storm is SHRINKING
--- TOWARD -- and it is NOT what BR.StormAt answers during a hold. StormAt is
--- honest about the wall as it stands: through a hold it returns the CURRENT
--- circle, `cx0, cy0, r0`, and only reaches the purple one once the sweep is
--- over. A destination tested against StormAt alone therefore qualifies against
--- the circle the player is standing in rather than the one they are being asked
--- to rotate to, which is exactly the ride he watched.
---
--- READ STRAIGHT OFF THE RECORD, for the reason shared/airdrop_solve.lua's
--- BR.AirdropLandingCircles gives for the same read: "BR.StormAt only reaches it
--- once the shrink is over", so anything solved from the clock cannot see it
--- during the hold that is precisely when it matters.
---
--- ═══ BOTH, NOT EITHER, AND BREAKOUT IS WHY ═══
---
--- Neither circle implies the other. config/storm.lua's BREAKOUT lets the next
--- circle leave the current one entirely (owner, 2026-08-06: "this will force
--- ALL players to move"), and the containment proof for "inside the next circle
--- implies inside the one on the way to it" needs |C1 - C0| <= r0 - r1, which is
--- precisely what a breakout violates. So a point can be deep inside the purple
--- circle and in the middle of the wall on arrival, or safe on arrival and
--- stranded thirty seconds later. airdrop_solve.lua reached this conclusion
--- first, for a crate rather than a player, and asks both questions for it.
---
--- A ZERO RADIUS REFUSES EVERY POINT AND THAT IS THE HONEST ANSWER, not a case
--- to guard against: config/storm.lua's phase 8 really is `radius = 0.0`, and a
--- final circle nothing can be inside of is a match in which the kit does not
--- work. See the refusal in BR.RescueDestination.
---
--- NO RECORD IS THE ONE CASE WITH NO CONSTRAINT -- an empty list. Before the
--- server publishes a storm there is nothing to be inside of, and refusing every
--- pre-storm rescue for that would be a rule with no circle behind it.
--- @param storm table|nil   the published storm record
--- @param eta number        server ms the ambulance is expected to arrive
--- @return table[]  array of { x, y, r }; EMPTY when no storm is published
function BR.RescueCircles(storm, eta)
    if not storm then return {} end

    local cx, cy, r = BR.StormAt(storm, eta)
    local out = { { x = cx + 0.0, y = cy + 0.0, r = r + 0.0 } }

    -- The purple one. Guarded on the FIELD rather than on its value, so a
    -- collapsed final circle refuses everything instead of quietly dropping the
    -- rule at the phase it matters most.
    if type(storm.r1) == 'number' then
        out[#out + 1] = {
            x = (storm.cx1 or 0.0) + 0.0,
            y = (storm.cy1 or 0.0) + 0.0,
            r = storm.r1 + 0.0,
        }
    end
    return out
end

--- Is (x, y) inside every one of these circles?
---
--- AN EMPTY LIST ANSWERS TRUE, which is what makes "no storm published" mean
--- "no constraint" rather than "nothing qualifies" -- the same convention
--- BR.AirdropInside uses, and for the same reason.
--- @param circles table[]  array of { x, y, r }
--- @param x number
--- @param y number
--- @return boolean
function BR.RescueInside(circles, x, y)
    for _, c in ipairs(circles or {}) do
        if not BR.InCircle(x, y, c.x or 0.0, c.y or 0.0, c.r or 0.0) then
            return false
        end
    end
    return true
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
--- ═══ WHEN NOTHING QUALIFIES THERE IS NO RESCUE. THE FALLBACK IS GONE ═══
---
--- Owner, 2026-08-28: "If no destinations are available within the PURPLE storm
--- circle - then cprkits are not available for use."
---
--- THIS REVERSES THE PARAGRAPH THAT USED TO STAND HERE, and the reversed
--- argument is worth keeping so nobody re-derives it: the old fallback picked
--- the point CLOSEST TO THE PREDICTED CENTRE on the reasoning that "delivering
--- the player somewhere is still much better than refusing the rescue after the
--- kit has been spent". The premise is false. The kit is NOT spent by the time
--- this answers -- server/rescue.lua reaches BR.Inv.take only after this
--- function has returned a destination -- so a refusal here costs the player
--- nothing at all, and the fallback was buying a delivery into the wall with an
--- item that was never at risk.
---
--- The remaining half of the old argument -- "driving to a point in the middle
--- of the wall would be worse" -- is exactly what the refusal now avoids.
---
--- IT IS STILL A NORMAL CASE RATHER THAN AN ERROR. Late in a match the purple
--- circle can be smaller than the gaps between twenty-three surveyed car parks,
--- and a nil return says so. The caller refuses the call, the player stays
--- downed with their kit, and nothing is shown to them.
---
--- `inside` IS THEREFORE ALWAYS TRUE FOR A NON-NIL ANSWER and is kept for the
--- callers that log it: it is now the difference between "qualified against a
--- circle" and "there was no circle to qualify against", which is still the
--- thing a playtest wants named.
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

    -- A point closer than this is the pickup by another name -- two surveyed
    -- car parks in the same forecourt would produce the same non-journey.
    local minTrip = (cfg and cfg.minTripM) or 150.0

    -- ═══ AND A CEILING, BECAUSE SEVEN MINUTES IS NOT A RESCUE ═══
    --
    -- Owner, 2026-08-29, after a ride solved at 4872m with a 432-second
    -- deadline: "let's cap it -- max 2000m".
    --
    -- The solver picks the NEAREST qualifying point, so distance was never
    -- chosen -- it was whatever the storm left. A phase that clears the map
    -- around the pickup produces a drive across most of it, and no amount of
    -- pathfinding makes seven minutes of watching an ambulance feel good.
    --
    -- IT NARROWS AN ALREADY-NARROW SET, and that is the cost worth naming: a
    -- destination must now be inside the next circle AND past minTripM AND
    -- within this. When nothing qualifies the kit REFUSES -- it is not
    -- consumed, no ambulance is built, the player stays down -- so a late
    -- circle far from any surveyed point makes the kit unusable rather than
    -- slow. That is the trade he asked for, stated rather than discovered.
    local maxTrip = (cfg and cfg.maxTripM) or 2000.0

    for _, p in ipairs(points or {}) do
        local d = BR.Dist(fromX, fromY, p.x, p.y)
        if (exclude and p == exclude) or d < minTrip or d > maxTrip then goto continue end

        -- This candidate's own arrival, the circle as it will be then, and the
        -- purple circle it is being asked to rotate to. An empty list is the
        -- pre-storm case and lets every point through -- see BR.RescueCircles.
        local eta = now + BR.RescueDriveMs(d, cfg)
        if BR.RescueInside(BR.RescueCircles(storm, eta), p.x, p.y) then
            if d < bestD then best, bestD = p, d end
        end
        ::continue::
    end

    if best then
        return best, bestD, storm ~= nil
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
--- ═══ A SPEED, NOT A DISTANCE PER TICK ═══
---
--- Owner, 2026-08-29: "please trigger the stuck fix if they are moving less
--- than 10mph for over 10 seconds".
---
--- This used to ask whether the ambulance had covered `progressM` since the
--- last time it was seen to move, which at a 1s judgement tick was an implicit
--- ~18mph floor -- and, worse, an implicit one. Nothing named a speed, so
--- nobody could reason about the threshold without also knowing the tick rate,
--- and changing either silently changed the other.
---
--- `prev` is the position at the last RESET, not the previous tick, so elapsed
--- is measured against the same moment as the distance and the two cannot
--- drift apart. An ambulance crawling at 9mph for nine seconds is not yet
--- stuck; the same ambulance at the eleventh second is.
--- @param prev table|nil    position when the stall clock was last reset
--- @param pos table|nil     position now
--- @param elapsedMs number  ms since that reset
--- @param cfg table|nil
--- @return boolean
function BR.RescueMoved(prev, pos, elapsedMs, cfg)
    if not prev or not pos then return false end
    local ms = tonumber(elapsedMs) or 0
    if ms <= 0 then return false end

    -- 1 mph = 0.44704 m/s, and the constant is written out rather than folded
    -- into a metres-per-second config so the number in the file is the number
    -- the owner said.
    local mps  = ((cfg or {}).minSpeedMph or 10.0) * 0.44704
    local need = mps * (ms / 1000.0)
    return BR.Dist(prev.x, prev.y, pos.x, pos.y) >= need
end

--- Is this ride over -- either because the ambulance got there, or because it
--- has stopped getting any closer?
---
--- ═══ EIGHT METRES WAS NEVER REACHABLE, AND THE DEADLINE WAS DELIVERING ═══
---
--- Owner, 2026-08-28, watching the first ride that drove the whole way: "when we
--- got near the destination the driver just started driving around aimlessly,
--- until eventually I was spawned at the destination on my own". The console
--- agreed in as many words -- "the deadline expired on a rescue that was
--- driving".
---
--- The destinations are CAR PARKS. The vehicle AI routes to the nearest road
--- node and, when the exact coordinate is not on the network, circles it. So the
--- ambulance really did arrive, never came within eight metres of the surveyed
--- point, and every ride was resolved by layer 4 of the recovery ladder instead
--- of by arriving.
---
--- THIS RULE IS STILL THE BACKSTOP AND STILL EARNS ITS PLACE. client/rescue.lua
--- now steers at a road node rather than at the forecourt, which should make
--- "at the point" the common ending -- but the snap depends on path nodes being
--- streamed in and can legitimately never resolve, and a car park genuinely
--- unreachable by road is still a real case. Nothing below changes.
---
--- ═══ THE OWNER REPLACED THE TEST WITH A DESIGN, WHICH IS THE BETTER FIX ═══
---
--- "If it can't arrive, I don't want it to circle. I want it to park as close as
--- it can get, even if that's on the road."
---
--- So there is no "cannot arrive" case left to detect. There is arriving, and
--- there is HAVING GOT AS CLOSE AS IT IS GOING TO GET -- and the second one is
--- what this function's second rule is. Both end the same way: the ambulance
--- parks (client/rescue.lua's `park`), and the ride is reported.
---
--- ═══ THE CLOSEST APPROACH IS THE SIGNAL, NOT THE SPEED ═══
---
--- A circling ambulance is MOVING, at speed, on a road, making no progress. A
--- speed test cannot see that and a stall test cannot either -- the server's own
--- `everMoved` sampling reads a lap as a healthy drive, correctly. What a lap
--- cannot do is IMPROVE ON ITS CLOSEST APPROACH: `bestM` is a running minimum,
--- so it stops falling the moment the vehicle starts going round rather than in.
--- A vehicle stopped in a car park has the same signature for the same reason,
--- which is why one rule covers both and there is no separate "is it parked".
---
--- BOTH RULES REQUIRE BEING NEAR THE DESTINATION. `bestM <= arriveNearM` is what
--- keeps a jam at eight hundred metres out of this: that is a stuck ambulance,
--- it is the server's to judge, and the recovery ladder has always handled it.
--- Only a vehicle that has reached the neighbourhood may declare the ride over
--- short of the point.
---
--- @param distM number       metres from the vehicle to the destination NOW
--- @param bestM number       the closest it has ever been on this ride
--- @param sinceBestMs number  ms since `bestM` last improved
--- @param cfg table|nil      BR.Config.Rescue
--- @return boolean arrived
--- @return string|nil why    for the log; nil when it has not
function BR.RescueArrived(distM, bestM, sinceBestMs, cfg)
    cfg = cfg or {}
    if (distM or math.huge) <= (cfg.arriveM or 25.0) then
        return true, 'at the point'
    end
    if (bestM or math.huge) <= (cfg.arriveNearM or 150.0)
       and (sinceBestMs or 0.0) >= (cfg.arriveGiveUpMs or 6000) then
        return true, 'as close as it got'
    end
    return false, nil
end

--- Is this spot clear of everybody who is not the player being rescued?
---
--- ═══ WHY AN AMBULANCE MAY NOT APPEAR NEXT TO SOMEBODY ═══
---
--- Owner, 2026-08-29: "make sure wherever the ambulance spawns there are no
--- other players within 500m".
---
--- This is not politeness about immersion. `board()` in client/rescue.lua fades
--- the screen out and TELEPORTS the downed player into the back of the vehicle
--- -- they never walk to it and it never drives to them -- so the spawn point is
--- where a rescued player physically MATERIALISES. Without this rule a kit can
--- drop its owner into somebody's crosshair, behind a fade they cannot see
--- through, with no input for the second it takes to be shot.
---
--- It is checked at DISPATCH and against the spawn only. The destination gets no
--- such test on purpose: it is minutes of driving away, every position this
--- function was handed will be stale by then, and a check that cannot be true
--- when it matters is worse than no check because it reads like a guarantee.
---
--- @param x number
--- @param y number
--- @param others table  array of { x = number, y = number } -- everyone else
--- @param clearM number|nil  metres, default 500
--- @return boolean
function BR.RescueClearOfPlayers(x, y, others, clearM)
    local need = clearM or 500.0
    for _, o in ipairs(others or {}) do
        if o and o.x and o.y and BR.Dist(x, y, o.x, o.y) < need then
            return false
        end
    end
    return true
end

--- Find somewhere to put the ambulance when no surveyed point will do.
---
--- ═══ THE SURVEYED POINTS ARE 23 CAR PARKS, AND THAT WAS THE WHOLE CEILING ═══
---
--- Owner, 2026-08-29, after the trip cap came down to 1000m: "when not possible,
--- start from a random point (nearest to the DBNO location), <1000m from the
--- destination, and make sure it starts on a road node."
---
--- The old rule spawned at the surveyed point nearest the downed player and drove
--- to another surveyed point. Both ends came from the same 23-row table, so the
--- ride only existed where two of those rows happened to sit within the trip
--- band of each other. Measured on the shipped data, at a 1000m cap that is true
--- for NINE of the 23 pickups -- the other fourteen have no legal destination at
--- all and the kit refuses.
---
--- Letting the SPAWN float fixes it from the other end, and the measurement says
--- so: sampling the playable area on a 100m lattice, 78.8% of it has a surveyed
--- destination inside 1000m. The cap stayed where the owner put it and the
--- coverage came from somewhere else.
---
--- ═══ THIS IS A FALLBACK, NOT A REPLACEMENT ═══
---
--- "when not possible" -- so server/rescue.lua tries the surveyed pickup first
--- and only comes here when that yields no destination or lands too near
--- somebody. The 39% of pickups that already work keep working exactly as they
--- did, on authored ground somebody stood on and checked.
---
--- ═══ NEAREST, SEARCHED OUTWARD, AND THAT IS WHY IT IS A RING WALK ═══
---
--- "nearest to the DBNO location" is the requirement, so candidates are visited
--- in order of increasing distance and the first one that passes wins. There is
--- no scoring pass and no shortlist: a spiral that returns on first success IS
--- the nearest qualifying point, and it stops doing work the moment it has one.
---
--- Bearings scale with the radius so the arc spacing stays roughly constant --
--- eight probes on a 100m ring and eight on a 900m ring would sample the far
--- ring nine times more sparsely and miss gaps the near one could not.
---
--- ═══ NO ROAD NODE IS CONSULTED HERE, BECAUSE NONE CAN BE ═══
---
--- "make sure it starts on a road node" is the other half of the request and it
--- CANNOT be answered in this function or anywhere else on the server: the
--- pathfind natives (GetClosestVehicleNodeWithHeading and its family) are client
--- only, and there is no server-side equivalent. What this returns is a
--- COORDINATE; client/rescue.lua's `board()` snaps it onto the nearest live road
--- node behind the fade it already draws, using the same flag-0-then-1 sequence
--- the stuck recovery uses -- and for the same reason, because bit 1 is
--- GCNF_INCLUDE_SWITCHED_OFF_NODES and that is the dirt the ambulance must not
--- start on if anything better exists.
---
--- THE CLIENT GAINS NOTHING IT DID NOT HAVE. It owns that vehicle either way and
--- could move it regardless of what ships here, so the snap adds no capability
--- and RESCUE_CALL stays payload-free -- "there is nothing about a rescue a
--- client could tell the server that the server should believe" still holds,
--- because the client is still told everything and asked nothing.
---
--- @param px number    where the player went down
--- @param py number
--- @param others table array of { x, y } -- every OTHER live player
--- @param points table the surveyed destination candidates
--- @param storm table|nil
--- @param now number
--- @param cfg table|nil
--- @param poly table|nil the map boundary; candidates outside it are skipped
--- @return table|nil spawn  { x, y } -- no z and no heading, both are the client's
--- @return table|nil dest   the destination that spot unlocked
--- @return number   dist    spawn-to-destination metres, or math.huge
function BR.RescueFreeSpawn(px, py, others, points, storm, now, cfg, poly)
    cfg = cfg or {}
    local reach   = cfg.spawnSearchM or 1200.0
    local ring    = cfg.spawnRingM or 100.0
    local clearM  = cfg.clearOfPlayersM or 500.0

    if ring <= 0 then return nil, nil, math.huge end

    -- Ring 0 is the player's own spot, and it is tried first because "nearest"
    -- has to mean nearest. It is only ever rejected by the two filters below,
    -- never by a rule about standing too close to the person being rescued --
    -- they are about to be teleported inside the vehicle regardless.
    local r = 0.0
    while r <= reach do
        local n = (r <= 0.0) and 1
            or math.max(8, math.floor((2.0 * math.pi * r) / ring))

        for i = 0, n - 1 do
            local a  = (2.0 * math.pi * i) / n
            local cx = px + math.sin(a) * r
            local cy = py + math.cos(a) * r

            -- Inside the playable area first: it is the cheapest test and the
            -- one that disqualifies most of a ring near the boundary. A spawn
            -- outside the map is a rescue that begins in the storm.
            local okHere = (poly == nil) or BR.PointInPolygon(cx, cy, poly)

            if okHere and BR.RescueClearOfPlayers(cx, cy, others, clearM) then
                local dest, dist, inside =
                    BR.RescueDestination(points, cx, cy, storm, now, cfg)
                if dest and inside then
                    return { x = cx, y = cy }, dest, dist
                end
            end
        end

        r = r + ring
    end

    return nil, nil, math.huge
end
