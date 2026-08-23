-- Airdrop solver.
--
-- Pure: no FiveM natives, no globals beyond BR. The same bet storm_solve.lua
-- and loot_gen.lua make, and for the same payoff -- tools/test_airdrop.lua can
-- prove the siting rule, the payout's determinism and the descent curve outside
-- the game, which is the cheapest feedback loop on this project.
--
-- THE DESCENT IS A PURE FUNCTION OF A PUBLISHED RECORD PLUS THE CLOCK, exactly
-- like BR.StormAt. That is not a stylistic choice: it is what lets the crate be
-- a LOCAL, non-networked object on every client and still be in the same place
-- on all of them. There is no position on the wire, so there is nothing for two
-- machines to disagree about -- which is the failure mode every physics-driven
-- FiveM airdrop has, and the reason they all end up networking the crate.
--
-- Load order: requires enums.lua, geo.lua (BR.Dist / BR.Clamp), rng.lua and
-- config/airdrop.lua.

BR = BR or {}

--- The record the server publishes once per drop.
---
---   {
---     n,           -- which drop of this match, 1-based; a re-send replaces
---     poi,         -- the POI id it is landing on, for logs
---     x, y,        -- the POI's own coordinates. "Airdrops should use standard
---                  --   POIs as coords" (owner) -- this is that, literally.
---     gz,          -- the POI's NOMINAL height, a hint only. Only a client can
---                  --   ground-probe, so this is what it falls back to.
---     alt,         -- metres ABOVE THE GROUND at tStart, never an absolute z
---     heading,     -- the crate's resting heading, AND the plane's bearing
---     tStart,      -- server time the drop was committed and the blip appeared
---     tRelease,    -- server time the plane is overhead and the crate leaves it
---     tLand,       -- server time it touches down and the sealed crate appears
---     tOpen,       -- server time a PLAYER opened it. ABSENT until then, and
---                  --   absent forever if nobody does -- which since the
---                  --   auto-open was removed (owner, 2026-08-22) is a case
---                  --   that really happens. Set by the server and the record
---                  --   re-broadcast, so every client's blip window agrees.
---   }
---
--- FOUR TIMESTAMPS AND ONLY THREE ARE KNOWN AT COMMIT. `tOpen` is the one the
--- server cannot predict, which is why it is written onto the published record
--- later and the record re-sent rather than being solved from anything: the
--- client's AIRDROP_SYNC handler has always treated a re-send with the same `n`
--- as a replacement, so the second send is the whole mechanism.
---
--- THREE TIMESTAMPS RATHER THAN TWO, and the middle one is what makes a plane
--- worth having. A record reaches a client AFTER tStart, so a flyover timed to
--- tStart would already be departing by the time anyone was told about it.
--- Announcing at tStart and releasing at tRelease gives the match a window in
--- which to look up and watch the thing arrive.
---
--- `tRelease` DEFAULTS TO `tStart`, so a record built the old way describes a
--- crate that appears in the sky the instant it is announced -- which is exactly
--- what this file did before the plane, and keeps every caller that has not
--- learned about the middle timestamp honest rather than broken.
--- @param n integer
--- @param poi table    a BR.Config.Map.POIs entry
--- @param alt number
--- @param tStart number
--- @param tLand number
--- @param heading number|nil
--- @param tRelease number|nil
--- @return table
function BR.BuildAirdropRecord(n, poi, alt, tStart, tLand, heading, tRelease)
    return {
        n        = n,
        poi      = poi.id,
        x        = poi.x + 0.0,
        y        = poi.y + 0.0,
        gz       = (poi.z or 0.0) + 0.0,
        alt      = alt + 0.0,
        heading  = (heading or 0.0) + 0.0,
        tStart   = tStart + 0.0,
        tRelease = (tRelease or tStart) + 0.0,
        tLand    = tLand + 0.0,
    }
end

--- A record for a drop that has been SITED and ANNOUNCED but is not falling.
---
--- ═══ THE ANNOUNCEMENT AND THE DESCENT ARE TWO EVENTS NOW ═══
---
--- Owner, 2026-08-22: "the drop should never happen until a player is within
--- 200m of the drop location. That way they get to see the drop happen."
---
--- A gate on "is somebody near the drop" is circular unless they have already
--- been told where it is. So the server sites the POI and announces it at
--- schedule time -- blip up, notification out, a place named -- and this is the
--- record that carries that. It has a `tStart` and NO `tRelease` and NO `tLand`,
--- because nothing is in the air: those two are the descent, and the descent is
--- what waits.
---
--- EVERY PREDICATE BELOW ANSWERS "NO" TO AN UNARMED RECORD -- released, landed,
--- plane visible, progress. The blip is the only thing a record in this state
--- draws, which is exactly what it is for.
--- @param n integer
--- @param poi table
--- @param alt number
--- @param tStart number
--- @param heading number|nil
--- @return table
function BR.BuildAirdropSite(n, poi, alt, tStart, heading)
    return {
        n       = n,
        poi     = poi.id,
        x       = poi.x + 0.0,
        y       = poi.y + 0.0,
        gz      = (poi.z or 0.0) + 0.0,
        alt     = alt + 0.0,
        heading = (heading or 0.0) + 0.0,
        tStart  = tStart + 0.0,
        -- tArm, tRelease and tLand are absent until somebody turns up.
    }
end

--- Somebody came. Start the descent.
---
--- MUTATES THE RECORD IN PLACE AND THE SERVER RE-BROADCASTS IT. The client's
--- AIRDROP_SYNC handler has always treated a record arriving with an `n` it
--- already holds as a replacement, so the second send is the whole mechanism --
--- the same one the open uses to stamp `tOpen`.
---
--- `tArm` IS NOT DECORATION AND IS NOT tRelease. It is when the WAIT ENDED, and
--- it is what the blip's four-minute ceiling is measured from once a drop has
--- armed. Measuring that ceiling from `tStart` would mean a drop that waited
--- three minutes for somebody has its blip expire twelve seconds after the crate
--- touches down -- and, worse, the client's teardown fires on the same
--- predicate, so the whole drop would be destroyed mid-descent.
--- @param rec table
--- @param now number
--- @param cfg table|nil  BR.Config.Airdrop
--- @return table rec
function BR.ArmAirdropRecord(rec, now, cfg)
    if not rec then return rec end
    cfg = cfg or {}
    rec.tArm     = now + 0.0
    rec.tRelease = now + (cfg.planeLeadMs or 0)
    rec.tLand    = rec.tRelease + (cfg.descentMs or 30000)
    return rec
end

--- Is this drop actually falling -- or has it merely been announced?
---
--- ONE FIELD ANSWERS IT, and it is `tLand` rather than a flag: a record either
--- has a landing time or it does not, and a separate boolean would be a second
--- thing to keep in step with it.
--- @param rec table|nil
--- @return boolean
function BR.AirdropArmed(rec)
    return rec ~= nil and rec.tLand ~= nil
end

--- How far the CLOSEST of these players is from (x, y), on the ground.
---
--- ═══ GROUND LEVEL TO GROUND LEVEL, AND THAT IS THE POINT ═══
---
--- Owner, 2026-08-22: "measured by the distance between the drop (at ground
--- level) and the closest player". So z is not in it at all: a crate 260m up is
--- 260m from somebody standing directly underneath it, and a gate that counted
--- the altitude would be gating on how high the plane flies rather than on how
--- far anybody has to walk.
---
--- PURE, so the gate can be tested outside the game -- which matters more here
--- than usual, because the alternative is proving it by getting 48 people to
--- stand in the right places.
---
--- `players` is an array of { x = , y = }; anything without both is skipped
--- rather than counted as being at the origin, which is a real position on this
--- map and would open the gate for a drop near Vespucci.
--- @param players table[]
--- @param x number
--- @param y number
--- @return number   metres; math.huge when nobody qualifies
function BR.AirdropClosest(players, x, y)
    local best = math.huge
    for _, p in ipairs(players or {}) do
        if p and type(p.x) == 'number' and type(p.y) == 'number' then
            local d = BR.Dist(p.x, p.y, x, y)
            if d < best then best = d end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Siting
-- ---------------------------------------------------------------------------

--- Every POI that will be at least `margin` metres INSIDE the given circle.
---
--- The circle passed in is the one solved for the moment the crate ARRIVES
--- (BR.StormAt(rec, tLand)), not the one showing now -- "a point which is going
--- to be within the circle by a minimum of 250m" is a statement about the
--- future, and the storm record is a pure function of time, so the server can
--- simply ask it.
---
--- ONE CIRCLE IS NOT THE RULE THE SERVER USES ANY MORE and this is now the
--- single-circle case of BR.AirdropSitesIn -- see the block below it for why a
--- drop is sited against a LIST. Kept as its own name because one circle is
--- still the honest way to ask "would this point be safe at that instant", which
--- is what every test of the margin actually wants to say.
---
--- Returned in AUTHORED POI ORDER, never a pairs() walk: the caller picks from
--- this with a seeded rng and a payout must replay identically from a seed.
---
--- CAN LEGITIMATELY BE EMPTY, and that is the whole reason this returns a list
--- rather than a POI. See the long note in config/airdrop.lua: the two rules the
--- owner gave -- use POIs, stay 250m inside -- have no common answer once the
--- circle is small, and the caller's job is to wait or to skip rather than to
--- bend one of them.
---
--- @param pois table[]        BR.Config.Map.POIs
--- @param cx number           circle centre at arrival
--- @param cy number
--- @param r number            circle radius at arrival
--- @param margin number       metres the point must be inside the rim by
--- @param placeable function|nil  (x, y) -> boolean; BR.LootPlaceable
--- @return table[] candidates
function BR.AirdropSites(pois, cx, cy, r, margin, placeable)
    return BR.AirdropSitesIn(pois,
        { { x = cx or 0.0, y = cy or 0.0, r = r or 0.0 } }, margin, placeable)
end

--- One of them, uniformly. nil when nothing qualifies.
---
--- BURNS NO RNG DRAW WHEN THERE IS NO CANDIDATE, deliberately: the caller
--- re-asks this every few seconds while a circle shrinks, and a failed check
--- that consumed a draw would make the payout depend on how many times the
--- question was asked.
--- @param rng table
--- @param pois table[]
--- @param cx number
--- @param cy number
--- @param r number
--- @param margin number
--- @param placeable function|nil
--- @return table|nil poi
--- @return integer candidateCount
function BR.AirdropPickSite(rng, pois, cx, cy, r, margin, placeable)
    return BR.AirdropPickSiteIn(rng, pois,
        { { x = cx or 0.0, y = cy or 0.0, r = r or 0.0 } }, margin, placeable)
end

-- ---------------------------------------------------------------------------
-- Siting against a WINDOW rather than an instant
-- ---------------------------------------------------------------------------
--
-- ═══ ONE CIRCLE WAS NEVER ENOUGH, AND THE 2026-08-23 PLAYTEST IS THE RECEIPT
--     ═══
--
-- Owner: "aidrops aren't spawning within the circle at all times. Perhaps to be
-- safe they should only spawn within the NEXT circle and spawn before the
-- beginning of phase 3?"
--
-- WHY IT WAS HAPPENING. The margin used to be solved ONCE, at siting, against
-- BR.StormAt(storm, now + planeLeadMs + descentMs) -- the SOONEST landing the
-- drop could have. Since the 200m gate (owner, 2026-08-22) the crate does not
-- leave for as long as it takes somebody to walk there, which the blip's own
-- ceiling caps at `blipMaxMs` -- FOUR MINUTES. A phase is 150-360 seconds long,
-- so the storm can complete a shrink and start another one inside that wait,
-- and the crate lands under a circle nobody solved anything against.
--
-- THE OLD FILE ARGUED THIS WAS SELF-CORRECTING: a point that ends up outside the
-- circle is a point nobody is near, so the gate never opens. IT IS NOT, and the
-- reason is the announcement -- the blip goes up at siting and TELLS the match
-- to go there. Players run to it, arm it from the rim, and the crate lands
-- exactly where the storm no longer is. The feature that was supposed to keep
-- anybody from being near an unsafe drop is the thing that delivers them to it.
--
-- ═══ SO A DROP IS SITED AGAINST EVERY CIRCLE IT COULD LAND UNDER ═══
--
-- Not one circle: a LIST, and the point has to clear all of them by the margin.
--
--   * the circle at the SOONEST landing  (somebody is already standing there)
--   * the circle at the LATEST landing   (the gate's own deadline)
--   * the circle the storm is shrinking TOWARD
--
-- THE FIRST TWO BOUND EVERY INSTANT BETWEEN THEM, and that is arithmetic rather
-- than optimism. Inside one published record the centre and the radius are both
-- LINEAR in time (BR.StormAt lerps them), so f(t) = |P - C(t)| - r(t) is convex
-- -- a norm of an affine function minus an affine function. A convex function
-- that is <= 0 at both ends of an interval is <= 0 across the whole of it. Two
-- checks therefore cover a four-minute window exactly, with nothing sampled and
-- nothing approximated.
--
-- THE THIRD IS THE OWNER'S "NEXT CIRCLE", and it is a separate check because
-- this storm's circles do not nest. config/storm.lua's BREAKOUT lets the next
-- circle leave the current one entirely (owner, 2026-08-06: "this will force ALL
-- players to move"), and the containment proof for "inside the next circle
-- implies inside every circle on the way to it" needs |C1 - C0| <= r0 - r1,
-- which is precisely what a breakout violates. So neither rule implies the
-- other and both are asked: the first two say the crate ARRIVES safe, the third
-- says it is still safe when the sweep it arrived during finishes.
--
-- BEYOND THIS PHASE NOTHING CAN BE PROMISED FROM HERE. The record describes one
-- phase; the circle after it has not been drawn and may break out anywhere. That
-- is what the re-check at the ARM is for -- see br_core/server/airdrop.lua.

--- Is (x, y) at least `margin` metres inside every one of these circles?
---
--- INCLUSIVE AT BOTH ENDS, which is the rule BR.AirdropSites has always had: a
--- point exactly `margin` inside the rim qualifies, and so does a POI standing
--- on the centre of a circle whose radius IS the margin.
---
--- NO EARLY RETURN FOR A NEGATIVE REACH, for the reason the single-circle
--- version recorded when a mutation pass showed the guard could not be killed: a
--- distance is never negative, so the comparison already refuses everything once
--- a circle is narrower than the margin.
--- @param circles table[]  array of { x, y, r }
--- @param x number
--- @param y number
--- @param margin number|nil
--- @return boolean
function BR.AirdropInside(circles, x, y, margin)
    local m = margin or 0.0
    for _, c in ipairs(circles or {}) do
        if BR.Dist(x, y, c.x or 0.0, c.y or 0.0) > (c.r or 0.0) - m then
            return false
        end
    end
    return true
end

--- Every POI that clears all of `circles` by `margin`.
---
--- Returned in AUTHORED POI ORDER, never a pairs() walk: the caller picks from
--- this with a seeded rng and a payout must replay identically from a seed.
---
--- CAN LEGITIMATELY BE EMPTY, and that is the whole reason this returns a list
--- rather than a POI. See the long note in config/airdrop.lua: the two rules the
--- owner gave -- use POIs, stay 250m inside -- have no common answer once the
--- circle is small, and the caller's job is to wait or to skip rather than to
--- bend one of them.
--- @param pois table[]        BR.Config.Map.POIs
--- @param circles table[]     array of { x, y, r }
--- @param margin number
--- @param placeable function|nil  (x, y) -> boolean; BR.LootPlaceable
--- @return table[] candidates
function BR.AirdropSitesIn(pois, circles, margin, placeable)
    local out = {}
    for _, poi in ipairs(pois or {}) do
        if BR.AirdropInside(circles, poi.x, poi.y, margin) then
            if not placeable or placeable(poi.x, poi.y) then
                out[#out + 1] = poi
            end
        end
    end
    return out
end

--- One of them, uniformly. nil when nothing qualifies.
--- @param rng table
--- @param pois table[]
--- @param circles table[]
--- @param margin number
--- @param placeable function|nil
--- @return table|nil poi
--- @return integer candidateCount
function BR.AirdropPickSiteIn(rng, pois, circles, margin, placeable)
    local candidates = BR.AirdropSitesIn(pois, circles, margin, placeable)
    if #candidates == 0 then return nil, 0 end
    return rng:pick(candidates), #candidates
end

--- The circles a drop committed at `now` has to clear, given that it may sit
--- for up to `waitMs` before anybody turns up to arm it.
---
--- `waitMs` IS THE WHOLE DIFFERENCE BETWEEN THE TWO CALLERS. At siting it is
--- the gate's deadline (`blipMaxMs`), because the landing time is unknown; at
--- the arm it is ZERO, because the landing time has just become exact. One
--- function, two windows, so the rule the drop was chosen under and the rule it
--- is re-checked against cannot drift apart.
---
--- A nil storm yields a circle of radius 0, which refuses every point on the
--- map. That is the right answer -- a drop cannot promise a margin against a
--- circle nobody has published -- and the server refuses earlier anyway
--- (BR.AirdropStormOk).
--- @param storm table|nil   the published storm record
--- @param now number
--- @param cfg table|nil     BR.Config.Airdrop
--- @param waitMs number|nil
--- @return table[]  array of { x, y, r }
function BR.AirdropLandingCircles(storm, now, cfg, waitMs)
    cfg = cfg or {}
    local flight  = (cfg.planeLeadMs or 0) + (cfg.descentMs or 30000)
    local soonest = now + flight
    local latest  = soonest + (waitMs or 0)

    local out = {}
    local function add(x, y, r)
        out[#out + 1] = { x = x + 0.0, y = y + 0.0, r = r + 0.0 }
    end

    local ax, ay, ar = BR.StormAt(storm, soonest)
    add(ax, ay, ar)
    if latest > soonest then
        local bx, by, br = BR.StormAt(storm, latest)
        add(bx, by, br)
    end
    -- THE CIRCLE THE STORM IS SHRINKING TOWARD -- the owner's "next circle".
    -- Read straight off the record rather than solved, because BR.StormAt only
    -- reaches it once the shrink is over and a drop landing mid-sweep would
    -- never be asked the question at all.
    if storm and type(storm.r1) == 'number' then
        add(storm.cx1 or 0.0, storm.cy1 or 0.0, storm.r1)
    end
    return out
end

--- The tightest of a set of circles, for a log line.
---
--- WHICH ONE DECIDED IT is the only thing a playtest can act on: "no POI
--- qualified" is unreadable, "no POI qualified inside a 950m circle at the
--- deadline" names the rule that refused.
--- @param circles table[]
--- @return number r  math.huge when there are none
function BR.AirdropTightest(circles)
    local best = math.huge
    for _, c in ipairs(circles or {}) do
        if (c.r or 0.0) < best then best = c.r or 0.0 end
    end
    return best
end

--- Is the storm early enough for a drop? "No airdrops past storm stage 4."
--- @param storm table|nil   the published storm record
--- @param maxPhase integer|nil
--- @return boolean
function BR.AirdropStormOk(storm, maxPhase)
    if not storm then return false end
    return (storm.phase or 0) <= (maxPhase or 4)
end

-- ---------------------------------------------------------------------------
-- The payout
-- ---------------------------------------------------------------------------

--- Roll one drop's contents.
---
--- SHUFFLE AND DEAL, NOT WEIGHTED DRAWS. A twelve-item drop rolled with
--- replacement gives you the same sniper three times often enough to matter,
--- and the whole point of a supply drop is that it is a KIT. Each pool is
--- shuffled once and dealt from in order; a pool shorter than the number of
--- slots pointing at it wraps, which is why the single-card `volts` pool pays
--- its slot rather than nothing.
---
--- DETERMINISTIC FOR A GIVEN SEED AND CONFIG. The decks are built in payout
--- order, so which cards come out depends only on the seed -- never on what
--- came out before.
---
--- ═══ HOW MANY, AND WHY THE COUNT IS DRAWN FIRST ═══
---
--- Owner, 2026-08-22: "instead of 'up to 12' items, let's make it 10-14 items in
--- these airdrops." So the number of slots dealt is itself a draw, taken from
--- `minItems`..`maxItems` inclusive.
---
--- IT IS THE FIRST DRAW THIS FUNCTION MAKES, before any deck is shuffled, and
--- that ordering is the whole of its determinism: the count cannot depend on the
--- shuffles and the shuffles cannot depend on the count, so a seed and a config
--- name one payout and one only.
---
--- IT COMES OFF THE AIRDROP'S OWN RNG, which is the rng this function is handed
--- and never any other. docs/match-math.md section 1 gives every subsystem a
--- prime of its own precisely so its draws cannot move another's; taking this
--- one from the loot stream would shift every downstream loot draw and silently
--- change every layout on the map.
---
--- THE ARRAY IS A PRIORITY ORDER, not a manifest -- see config/airdrop.lua. The
--- first `minItems` slots are what every drop is guaranteed to hold, so a short
--- roll is a complete kit rather than a kit with the ammo missing.
---
--- @param rng table
--- @param cfg table|nil  defaults to BR.Config.Airdrop
--- @return table[] stacks
function BR.AirdropPayout(rng, cfg)
    cfg = cfg or BR.Config.Airdrop
    local pools = cfg.resolvedPools or {}
    local slots = cfg.payout or {}

    -- CLAMPED TO THE ARRAY, not trusted to it. `maxItems` above #payout would
    -- otherwise ask for slots that do not exist and quietly pay fewer items
    -- than the config says -- the failure a range is most likely to grow into
    -- the day somebody shortens the array. tools/test_airdrop.lua pins the
    -- committed pair as well, so this clamp is the second line rather than the
    -- first.
    local lo = math.tointeger(cfg.minItems or #slots) or #slots
    local hi = math.tointeger(cfg.maxItems or #slots) or #slots
    lo = math.max(0, math.min(lo, #slots))
    hi = math.max(lo, math.min(hi, #slots))

    -- THE COUNT IS DRAWN BEFORE ANY DECK IS SHUFFLED, so neither can move the
    -- other. Rng:int burns NO draw when lo == hi, which is deliberate over
    -- there and worth knowing here: pinning minItems == maxItems consumes
    -- exactly the rng a fixed-count payout always did, so the old behaviour is
    -- still reachable byte for byte from one config line.
    local n = rng:int(lo, hi)

    local decks, dealt = {}, {}
    local out = {}

    for i = 1, n do
        local name = slots[i]
        local src = pools[name]
        if src and #src > 0 then
            local deck = decks[name]
            if not deck then
                deck = {}
                for j = 1, #src do deck[j] = src[j] end
                rng:shuffle(deck)
                decks[name], dealt[name] = deck, 0
            end

            dealt[name] = dealt[name] + 1
            local t = deck[((dealt[name] - 1) % #deck) + 1]

            -- A COPY, never the template. These become ground entries that the
            -- inventory then mutates (a magazine is spent, a stack is split),
            -- and handing out the shared template would let one pickup rewrite
            -- what every future drop contains.
            out[#out + 1] = {
                item   = t.item,
                kind   = t.kind,
                rarity = t.rarity,
                count  = t.count,
                clip   = t.clip,
                -- Carried because the Volts pile names its own model: every
                -- other kind resolves a prop from its id on the client, and
                -- 'volts' is not an id any config table holds.
                prop   = t.prop,
            }
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- The descent
-- ---------------------------------------------------------------------------

--- How far through the fall, 0 at the RELEASE and 1 at tLand.
---
--- MEASURED FROM tRelease, NOT tStart. The fall begins when the crate leaves the
--- plane; the announcement is `planeLeadMs` earlier and is when the blip goes up,
--- not when anything starts moving. On a record with no tRelease the two are the
--- same instant and this is what it always was.
--- @param rec table|nil
--- @param now number  server time
--- @return number
function BR.AirdropProgress(rec, now)
    -- AN UNARMED RECORD HAS NOT STARTED, NOT FINISHED. A drop that has been
    -- announced and is waiting for somebody to come within 200m has no tLand at
    -- all, and the old arithmetic would have read that missing number as zero
    -- and reported the crate fully descended -- which is the wrong end of the
    -- fall and the same shape as the 2026-08-22 teardown bug.
    if not BR.AirdropArmed(rec) then return 0.0 end
    local from = rec.tRelease or rec.tStart or 0.0
    local span = (rec.tLand or 0.0) - from
    if span <= 0.0 then return 1.0 end
    return BR.Clamp((now - from) / span, 0.0, 1.0)
end

--- Has the crate left the plane yet?
---
--- The crate does not exist before this: it is inside the aircraft. Drawing one
--- during the lead-in would put a box in the sky under a plane that has not
--- reached it, which is the picture the lead-in exists to replace.
--- @param rec table|nil
--- @param now number
--- @return boolean
function BR.AirdropReleased(rec, now)
    -- NOTHING IS RELEASED FROM AN AIRCRAFT THAT HAS NOT BEEN SENT. A sited drop
    -- carries a tStart and no tRelease, and falling back to tStart here would
    -- put a crate in the sky the instant the blip appeared -- which is the whole
    -- of what the 200m gate exists to prevent.
    if not BR.AirdropArmed(rec) then return false end
    return now >= (rec.tRelease or rec.tStart or 0.0)
end

--- Metres above the ground at `now`. Linear, because a canopy falls at
--- terminal velocity -- there is no acceleration to model.
--- @param rec table|nil
--- @param now number
--- @return number
function BR.AirdropHeightAt(rec, now)
    if not rec then return 0.0 end
    return (rec.alt or 0.0) * (1.0 - BR.AirdropProgress(rec, now))
end

-- ---------------------------------------------------------------------------
-- The plane
-- ---------------------------------------------------------------------------

--- Is the delivery plane in the world at `now`?
---
--- From the announcement until `trailMs` after the release. Deliberately NOT
--- until the crate lands: the aircraft's job is over the moment the box leaves
--- it, and a Titan orbiting the drop for another half-minute is scenery arguing
--- with the fight underneath it.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil  BR.Config.Airdrop
--- @return boolean
function BR.AirdropPlaneVisible(rec, now, cfg)
    -- NO AIRCRAFT UNTIL THE DROP IS ARMED. It used to arrive with the
    -- announcement; the announcement now happens minutes earlier, while the
    -- drop waits for somebody to come within 200m, and a Titan circling for
    -- those minutes is exactly the empty-sky flyover the gate was added to stop.
    if not BR.AirdropArmed(rec) then return false end
    cfg = cfg or {}
    -- FROM THE ARM, NOT FROM tStart. `tArm` is when the wait ended and the
    -- aircraft was dispatched; tStart is when the blip went up.
    if now < (rec.tArm or rec.tStart or 0.0) then return false end
    return now <= (rec.tRelease or rec.tStart or 0.0)
                + (cfg.planeTrailMs or 15000)
end

--- Where the delivery plane is at `now`.
---
--- A STRAIGHT LINE AT CONSTANT SPEED, passing exactly over the drop point at
--- tRelease. That is the whole model, and it is the whole model on purpose: it
--- is a pure function of the published record and the clock, so every client's
--- plane is in the same place at the same millisecond with nothing on the wire
--- and nothing simulated -- the same bargain the crate, the storm and the bus
--- route already make. A flight path with any state in it would be the one part
--- of a drop that could desync.
---
--- THE BEARING IS `rec.heading`, which is also the crate's resting heading. One
--- number doing two jobs is not a shortcut here: it means the box lands pointing
--- the way the plane that dropped it was going.
---
--- z IS METRES ABOVE THE GROUND, never an absolute height -- only a client can
--- ground-probe, so the caller adds its own answer. Same rule as `rec.alt`.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil  BR.Config.Airdrop
--- @return number x
--- @return number y
--- @return number zAboveGround
--- @return number heading
function BR.AirdropPlaneAt(rec, now, cfg)
    if not rec then return 0.0, 0.0, 0.0, 0.0 end
    cfg = cfg or {}

    local hdg = rec.heading or 0.0
    -- GTA forward for a heading: (-sin, cos). See BR.AirdropOffsetAt for the
    -- convention and why it is the half that gets written backwards.
    local a  = math.rad(hdg)
    local fx, fy = -math.sin(a), math.cos(a)

    -- Signed: NEGATIVE before the release, which is the inbound leg the whole
    -- lead-in exists to show.
    local dt = (now - (rec.tRelease or rec.tStart or 0.0)) / 1000.0
    local d  = (cfg.planeSpeed or 90.0) * dt

    return (rec.x or 0.0) + fx * d,
           (rec.y or 0.0) + fy * d,
           (rec.alt or 0.0) + (cfg.planeAltAbove or 40.0),
           hdg
end

-- ---------------------------------------------------------------------------
-- ...AND WHAT IS BETWEEN IT AND THE DROP
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-23: "We also need a way to make sure the cargobob avoids
-- terrain, because drops at chili[ad]".
--
-- THE FLIGHT PLAN IS FLAT AND IT IS PINNED TO THE WRONG GROUND. `rec.alt` and
-- `planeAltAbove` are both measured from the ground AT THE DROP POINT, so the
-- aircraft holds one absolute height for the whole run-in: groundAtDrop + 195.
-- Nothing in it has ever looked at what the run-in crosses. Site a drop at
-- `chiliad_e` (authored z 160) and the corridor behind it climbs into a massif
-- whose summit POI is authored at 780 -- the Cargobob is six hundred metres
-- inside the rock, and the only reason it has never been a crash is that
-- client/airdrop.lua switches its collision off.
--
-- ═══ THE FIX IS A FLOOR UNDER THE FLIGHT PLAN, NOT A NEW FLIGHT PLAN ═══
--
-- The route stays a straight line at constant speed passing over the drop point
-- at tRelease -- that is what makes every client's aircraft the same pure
-- function of the record and the clock. What changes is the HEIGHT, and only
-- upward: the aircraft flies at whichever is higher, its nominal altitude or a
-- fixed clearance above the highest ground still ahead of it.
--
-- IT IS EXACT AT THE RELEASE BY CONSTRUCTION, which is the property that stops
-- this from costing the drop its geometry. The corridor below is measured from
-- where the aircraft IS to where it will be `horizonMs` later, clipped at
-- tRelease -- so as the release approaches the corridor collapses onto the drop
-- point, the highest ground in it is the ground under the crate, and the floor
-- falls back below the nominal altitude. The crate leaves the aircraft exactly
-- `planeAltAbove` beneath it however high the ridge behind them was.
--
-- THE PROBING IS THE CLIENT'S (GetGroundZFor_3dCoord is a client native, the
-- same rule `rec.alt` is written under), and it FAILS OPEN: a corridor nothing
-- answers for leaves the aircraft at its nominal height, which is exactly
-- today's behaviour.

--- The points to ground-probe for an aircraft's approach at `now`.
---
--- FROM WHERE IT IS TO WHERE IT IS GOING, never the whole route: the ridge
--- behind the aircraft is not its problem, and a corridor that kept it would
--- hold the Cargobob high all the way to a drop point at sea level.
---
--- CLIPPED AT tRelease ON THE INBOUND LEG. That clip is what makes the lift
--- vanish exactly when the crate leaves -- see the block above. After the
--- release the horizon runs full length again, because the aircraft still has
--- `planeTrailMs` of flying to do and the ridge in FRONT of it is real.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil     BR.Config.Airdrop
--- @param samples integer|nil  how many points, ends included (min 2)
--- @param horizonMs number|nil how far ahead to look, in ms of flight
--- @return table[]  array of { x, y }
function BR.AirdropApproach(rec, now, cfg, samples, horizonMs)
    local out = {}
    if not rec then return out end
    cfg = cfg or {}

    local n = math.tointeger(samples or 8) or 8
    if n < 2 then n = 2 end

    -- CLIPPED AT tRelease INCLUSIVELY -- `<=`, not `<`. On the frame of the
    -- release itself the corridor has to be a POINT, or the terrain in front of
    -- the aircraft could still be lifting it on the one frame where the crate
    -- leaves and the gap between them has to be exactly `planeAltAbove`.
    local tRel = rec.tRelease or rec.tStart or 0.0
    local tEnd = now + (horizonMs or 6000)
    if now <= tRel and tEnd > tRel then tEnd = tRel end

    for i = 0, n - 1 do
        local t = now + (tEnd - now) * (i / (n - 1))
        local x, y = BR.AirdropPlaneAt(rec, t, cfg)
        out[#out + 1] = { x = x, y = y }
    end
    return out
end

--- How high the aircraft actually flies, given what is under its approach.
---
--- UPWARD ONLY. `nominalZ` is the flight plan and this can never lower it: an
--- aircraft that dipped toward a valley would arrive under the crate's release
--- height, and the crate's height is the record's business and nobody else's.
---
--- A nil `terrainZ` is "nothing answered", not "no terrain". It returns the
--- nominal height -- the behaviour this file had before terrain was considered
--- at all -- because a probe that cannot see must never be read as a probe that
--- saw flat ground.
--- @param nominalZ number       absolute z the flight plan wants
--- @param terrainZ number|nil   highest ground along the approach, absolute
--- @param clearance number|nil  metres to hold above it
--- @return number z
function BR.AirdropPlaneZ(nominalZ, terrainZ, clearance)
    if type(terrainZ) ~= 'number' then return nominalZ end
    local floor = terrainZ + (clearance or 60.0)
    if floor > nominalZ then return floor end
    return nominalZ
end

--- Which way the crate is facing at `now`, in degrees.
---
--- The resting heading plus a slow turn over the whole descent: a crate under a
--- canopy that never rotates reads as a prop sliding down an invisible rail.
---
--- IT IS HERE RATHER THAN IN THE CLIENT because the flares hang off it. Their
--- world positions are the crate's position plus an offset ROTATED BY THIS
--- ANGLE, so a heading computed in one place and an offset rotated in another
--- is two chances to disagree about which way "left" is.
--- @param rec table|nil
--- @param now number
--- @param spinDeg number|nil  degrees turned across the whole fall
--- @return number
function BR.AirdropHeadingAt(rec, now, spinDeg)
    if not rec then return 0.0 end
    return (rec.heading or 0.0)
         + BR.AirdropProgress(rec, now) * (spinDeg or 0.0)
end

--- Where a point rigidly fixed to the crate is, in the WORLD, at `now`.
---
--- WHY THIS EXISTS AT ALL, AND WHY IT IS NOT ATTACH_ENTITY_TO_ENTITY. The
--- canopy and the two flares are parts of one falling object. GTA's own crate
--- drop bolts them on with ATTACH_ENTITY_TO_ENTITY; we write their coordinates
--- instead, from the same solver the crate's come from, because that is the
--- design the rest of this file is: every position in a drop is a pure function
--- of the published record and the synced clock, so there is nothing for two
--- machines to disagree about. An attachment would be a second mechanism
--- deciding where something is -- one the engine owns, that no test can see, and
--- whose behaviour on two LOCAL non-networked objects is not something anything
--- outside a running client can answer. Same result, one mechanism, testable.
---
--- `ox` is the crate's own RIGHT and `oy` its FORWARD, in metres, exactly as an
--- attach offset would be -- so Rockstar's numbers transfer unchanged.
--- @param rec table|nil
--- @param now number
--- @param ox number    metres to the crate's right
--- @param oy number    metres forward
--- @param spinDeg number|nil
--- @return number x
--- @return number y
function BR.AirdropOffsetAt(rec, now, ox, oy, spinDeg)
    if not rec then return 0.0, 0.0 end

    -- GTA HEADINGS: 0 is north (+Y) and the angle grows ANTICLOCKWISE, so an
    -- entity's forward is (-sin h, cos h) and its right is (cos h, sin h). Put
    -- those two together and it is the ordinary rotation matrix -- but only
    -- because forward is +Y rather than +X, which is the half that is easy to
    -- get backwards and puts both flares on the same side of the crate.
    local a = math.rad(BR.AirdropHeadingAt(rec, now, spinDeg))
    local c, s = math.cos(a), math.sin(a)
    ox, oy = ox or 0.0, oy or 0.0
    return (rec.x or 0.0) + ox * c - oy * s,
           (rec.y or 0.0) + ox * s + oy * c
end

--- Has it touched down?
--- @param rec table|nil
--- @param now number
--- @return boolean
function BR.AirdropLanded(rec, now)
    -- A drop that is still waiting to be sent has not landed, and asking it
    -- would have indexed a nil tLand. The server's own tick reads this to decide
    -- when to put the crate on the ground.
    if not BR.AirdropArmed(rec) then return false end
    return now >= rec.tLand
end

--- The exact server time this drop's blip goes out.
---
--- ═══ ONE FUNCTION, BECAUSE THERE ARE TWO PREDICATES OVER IT ═══
---
--- BR.AirdropBlipVisible and BR.AirdropExpired both need this instant, they are
--- read on different frames by different code, and a drop whose blip is drawn
--- past the moment its record is destroyed (or the other way round) is exactly
--- the class of bug that cost the owner a round on 2026-08-22. So the boundary
--- is computed once and both ask for it.
---
--- THE RULE (owner, 2026-08-22: "we keep the blip on until 1 minute after the
--- crate is opened, or no longer than 4 minutes if unopened, which would also
--- be the case if nobody got to the location in time"):
---
---   opened at rec.tOpen  ->  rec.tOpen           + afterOpenMs
---   never opened         ->  (rec.tArm or tStart) + maxMs
---
--- CONFIRMED VERBATIM (owner, 2026-08-22): "The blip should be 4 minutes. If
--- nobody opens it. If someone opens it, the blip should remain for 1 minute
--- after opening. That's what I meant, which I guess could total to 5."
---
--- MEASURED FROM tStart AND NOT FROM tLand, which is a change of origin as well
--- as of number. The old window was "a minute after it lands"; the ceiling now
--- covers the announcement, the plane's run-in, the fall AND the search, because
--- that whole span is time the owner spent not knowing where to go.
---
--- ═══ AND FROM tArm ONCE THERE IS ONE, WHICH IS THE 200m GATE'S DOING ═══
---
--- The ceiling now has two jobs, and they are the same instant seen from two
--- sides. Before the drop arms it is the DEADLINE FOR SOMEBODY TO TURN UP --
--- "the allotted time" in the owner's sentence about no drop happening -- and
--- the server abandons the drop at exactly the moment the blip goes out, so the
--- two cannot disagree. After it arms it is the ordinary unopened-blip life.
---
--- SO THE CLOCK RESTARTS AT THE ARM, and it has to. A drop that waited three
--- minutes for somebody would otherwise have its blip expire twelve seconds
--- after the crate touched down -- and far worse, the client's teardown fires on
--- this same boundary, so the entire drop would be destroyed mid-descent with a
--- crate visibly in the air. One clock for two jobs only works if it is reset
--- when the job changes.
---
--- IN PRACTICE THE POST-ARM CEILING IS ALMOST NEVER REACHED, because the gate
--- guarantees somebody was within 200m at the moment it armed: they open it, and
--- `tOpen + afterOpenMs` governs. It is a backstop for the player who died on
--- the way or thought better of it.
---
--- OPENING IT MAKES THE WINDOW SHORTER IN THE ORDINARY CASE and that is the
--- intent, not an oversight: a drop opened forty seconds after it lands has one
--- minute of blip left rather than three. The blip exists to get somebody there.
---
--- NO min() WITH THE CEILING, deliberately. A crate opened at 3m55 keeps its
--- blip to 4m55, five seconds past the nominal ceiling, because the owner's
--- sentence attaches the 4 minutes to "if unopened". A crate opened LATER than
--- the ceiling cannot extend anything, because the record is already gone (see
--- BR.AirdropExpired) and there is nothing left to re-announce it to.
--- @param rec table|nil
--- @param cfg table|nil  BR.Config.Airdrop
--- @return number
function BR.AirdropBlipEndsAt(rec, cfg)
    if not rec then return 0.0 end
    cfg = cfg or {}
    if rec.tOpen then
        return rec.tOpen + (cfg.blipAfterOpenMs or 60000)
    end
    return (rec.tArm or rec.tStart or 0.0) + (cfg.blipMaxMs or 240000)
end

--- Should the map blip be up?
---
--- From the moment the drop is announced until BR.AirdropBlipEndsAt. One
--- expression, so the client's blip and any test of it cannot disagree about the
--- window.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil  BR.Config.Airdrop
--- @return boolean
function BR.AirdropBlipVisible(rec, now, cfg)
    if not rec then return false end
    if now < rec.tStart then return false end
    return now <= BR.AirdropBlipEndsAt(rec, cfg)
end

--- Is there nothing left of this drop to draw, ever again?
---
--- ═══ THIS IS A SEPARATE QUESTION FROM THE ONE ABOVE, AND CONFLATING THEM COST
---     THE OWNER A ROUND (playtest, 2026-08-22: "I randomly got a notification
---     for airdrop, but didn't see it on the map so wasn't sure where to go to
---     see it.") ═══
---
--- The client used to tear a drop down -- blip, crate, record, the lot --
--- whenever BR.AirdropBlipVisible answered false. That predicate is false at
--- BOTH ends: after the linger expires, and ALSO for a `now` that has not
--- reached tStart yet. The second one is not "this drop is over", it is "this
--- drop has not started"; treating it as teardown destroys the drop on the first
--- frame and it never comes back.
---
--- AND A CLIENT CAN GENUINELY BE THERE. `tStart` is the SERVER's GetGameTimer()
--- at the moment of commit; the client compares it against BR.Clock.now(), which
--- is its local timer plus a MEDIAN-OF-EIGHT ESTIMATE of the offset (see
--- clock.lua, which budgets for ~100ms of error and says so). The record reaches
--- the client about half a round trip after tStart, so the comparison only has
--- one-way latency of headroom -- and any client whose estimate is running
--- behind by more than that loses its airdrop entirely, having just been told
--- one was coming. Nothing else in the file would notice: no error, no log, one
--- missing blip per match.
---
--- So teardown asks THIS, which is only ever true at the far end. A record from
--- the future is simply not due yet, and waiting for it costs a frame.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil  BR.Config.Airdrop
--- @return boolean
function BR.AirdropExpired(rec, now, cfg)
    if not rec then return true end
    return now > BR.AirdropBlipEndsAt(rec, cfg)
end
