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
---
--- ═══ tLand IS NO LONGER tRelease + descentMs, AND THAT IS THE 2026-08-28 FLARE
---     ═══
---
--- `descentMs` stopped being the length of the fall on the day the crate started
--- slowing down near the ground: it is now the length of the fall AT THE CRUISE
--- RATE, which is the number the owner confirmed and the one thing that must not
--- move. The tail is longer than the cruise it replaces, so the landing time is
--- BR.AirdropFallMs -- descentMs times a stretch the curve itself decides. See
--- the fall-curve block below for that number and where it comes from.
---
--- IT IS SOLVED FROM `rec.alt`, NOT FROM `cfg.altitude`, because the record's own
--- altitude is what the crate actually falls through: the cruise rate is
--- `rec.alt / descentMs` at any altitude, exactly as it always was.
--- @param rec table
--- @param now number
--- @param cfg table|nil  BR.Config.Airdrop
--- @return table rec
function BR.ArmAirdropRecord(rec, now, cfg)
    if not rec then return rec end
    cfg = cfg or {}
    rec.tArm     = now + 0.0
    rec.tRelease = now + (cfg.planeLeadMs or 0)
    rec.tLand    = rec.tRelease + BR.AirdropFallMs(cfg, rec.alt)
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
    -- THE WHOLE FLIGHT, WHICH IS LONGER THAN `descentMs` SINCE THE FLARE. The
    -- margin is a promise about where the crate ARRIVES, so the instant it is
    -- solved against has to be the real landing time -- BR.AirdropFallMs, not
    -- the cruise-rate reference the crate no longer falls the whole way at.
    local flight  = (cfg.planeLeadMs or 0) + BR.AirdropFallMs(cfg)
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

--- How far through the fall IN TIME, 0 at the RELEASE and 1 at tLand.
---
--- ═══ THIS IS THE CLOCK, NOT THE HEIGHT, AND SINCE 2026-08-28 THEY DIFFER ═══
---
--- It used to be both: the descent was linear, so "half the seconds" and "half
--- the metres" were one number and this function was asked for either. The crate
--- now flares out near the ground (see the fall-curve block below), so the two
--- have separated and each has its own reader -- BR.AirdropFallen is the HEIGHT
--- and is what the crate, the canopy and the flares are drawn off. This stays
--- the TIME, which is what the blip's windows and the crate's slow turn want.
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

-- ---------------------------------------------------------------------------
-- THE FALL CURVE -- CRUISE, THEN A FLARE
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-28: "please make the speed of the air drop a function of it's
-- height - as it drops the current speed is correct, but as it reaches the
-- ground it should slow down exponentially to 25% of the current set speed. The
-- final speed should be achieved roughly 25ft before it touches down."
--
-- ═══ IT IS STILL A PURE FUNCTION OF THE RECORD AND THE CLOCK, AND THAT WAS THE
--     ONLY HARD CONSTRAINT ═══
--
-- Everything at the top of this file about the crate being a LOCAL, non-
-- networked object on every client rests on one property: its position is
-- decided by arithmetic over a published record and a synced clock, so there is
-- nothing for two machines to disagree about. A speed that "responds to the
-- ground" would be a per-client simulation and would take that away. So the
-- curve below reads NOTHING but the elapsed time, `rec.alt` and the config. No
-- probe, no state, no frame history. Ask it twice and it answers twice the same.
--
-- ═══ THE FUNCTION, WHICH IS AN EXPONENTIAL IN HEIGHT AND NOT IN TIME ═══
--
-- The owner's sentence is literally "a function of its height", and taking that
-- literally is also what makes the 25ft mark EXACT rather than approximate.
-- With `h` the height above the landing point, `V` the cruise rate, `F` the
-- final rate (25% of V), `b` the flare height (25ft = 7.62m) and `L` the
-- e-folding height:
--
--     v(h) = V - (V - F) * exp(-(h - b) / L)        for h >= b
--     v(h) = F                                      for h <  b
--
-- AT h = b THE EXPONENT IS ZERO, so v(b) = V - (V - F) = F -- the final speed
-- is REACHED at the flare height, on the nose, and is then held to touchdown.
-- An exponential written in TIME cannot do that: it approaches its asymptote
-- and never arrives, so "the final speed is achieved 25 feet up" would have had
-- to become "within a few percent of it, at a height nobody chose".
--
-- AND THERE IS NO KNEE AT THE TOP. exp(-(h - b)/L) is 4e-13 at the release
-- height, so v(alt) is the cruise rate to thirteen decimal places and the
-- deceleration simply grows out of it. The curve is ONE smooth expression from
-- the release to the flare -- there is no moment where a constant phase hands
-- over to a decelerating one, which is the gear-change this shape was chosen to
-- avoid. The only corner left is at `b`, and it is a corner in ACCELERATION
-- with the speed itself continuous: the crate is 7.6m up doing 3.75 m/s when it
-- happens, and holding the final rate for the last 25 feet is the thing the
-- owner asked for rather than an artefact.
--
-- ═══ AND IT INTEGRATES IN CLOSED FORM, WHICH IS WHY IT IS HERE AND NOT A
--     PER-FRAME EULER STEP ═══
--
-- A speed law is not directly usable: the client needs height FROM TIME, once,
-- with no accumulated state (a stepped integration is per-client state by
-- another name and would desync). Working in fractions -- phi = h/alt, beta =
-- b/alt, eps = L/alt, rho = F/V, D = 1 - rho, and theta the elapsed time in
-- units of the reference fall alt/V -- the integral inverts exactly:
--
--     m(theta) = exp((theta - 1 + beta)/eps) / vTop
--     phi      = 1 - theta + eps * ln(vTop * (1 + D * m))
--
-- with vTop = 1 - D*exp(-(1 - beta)/eps), the release speed as a fraction of
-- cruise. It is exact at both ends by construction: m -> vTop^-1 at theta = 0
-- gives phi = 1, and m = 1/rho at the flare gives phi = beta. The speed falls
-- out of the same algebra as v/V = 1/(1 + D*m), which is what BR.AirdropSpeedAt
-- returns and what the suite checks the 25% against.
--
-- ═══ WHAT IT COSTS IS TIME, AND THE COST IS DERIVED RATHER THAN HIDDEN ═══
--
-- "The current speed is correct" is a statement about the RATE, and there were
-- two ways to honour it. Keeping `descentMs` as the total would have paid for
-- the slow tail by making the early fall FASTER than the rate the owner just
-- confirmed. So the rate is what is held: the cruise is still `alt / descentMs`
-- -- 225m in 15s, 15 m/s, exactly what it was -- and the fall simply takes
-- longer by however long the tail is. At the shipped numbers:
--
--     cruise above the flare   217.38m at 15 m/s   14.492s
--     the exponential tail                          0.704s
--     the flare, 7.62m at 3.75 m/s                  2.032s
--                                                  -------
--     BR.AirdropFallMs                             17.228s   (descentMs x 1.1485)
--
-- THAT NUMBER IS SOLVED, NOT WRITTEN DOWN. BR.ArmAirdropRecord builds `tLand`
-- out of it, tools/test_airdrop.lua pins it, and /brairdrop prints it -- so the
-- two seconds are visible in three places rather than being a thing the crate
-- does that nobody wrote down.

--- The curve, reduced to the numbers every reader of it needs.
---
--- SOLVED FROM SCRATCH ON EVERY CALL, deliberately: it is a dozen flops with no
--- allocation worth caching, and a cache would be the one piece of state in a
--- descent whose entire design is that it has none.
---
--- A cfg WITHOUT `slowTo` IS A LINEAR FALL, which is not a fallback so much as
--- the old behaviour staying reachable: rho collapses to 1, the flare height
--- stops mattering, `total` is exactly 1 and every function below is the
--- straight line it was before 2026-08-28. Tests that pass a hand-built cfg get
--- that, and passing no cfg at all reads BR.Config.Airdrop and gets the flare.
--- @param alt number|nil   the record's own release altitude, metres
--- @param cfg table|nil    defaults to BR.Config.Airdrop
--- @return table  { beta, eps, rho, d, vTop, lnvTop, thetaB, total }
function BR.AirdropFallShape(alt, cfg)
    cfg = cfg or BR.Config.Airdrop or {}
    alt = (type(alt) == 'number' and alt > 0.0) and alt or 0.0

    local rho = cfg.slowTo
    rho = (type(rho) == 'number' and rho > 0.0 and rho < 1.0) and rho or 1.0

    -- CLAMPED TO THE ALTITUDE. A flare height at or above the release height is
    -- a drop that is in its flare the whole way down, and the arithmetic below
    -- resolves that case rather than being protected from it -- beta goes to 1,
    -- the exponential phase has zero length, and the fall is a straight line at
    -- the final rate. The alternative, refusing it, would be a silent linear
    -- fall at the CRUISE rate, which is the wrong one of the two.
    local b = cfg.slowHeight
    b = (type(b) == 'number' and b > 0.0) and b or 0.0
    if b > alt then b = alt end

    local lam = cfg.slowEFold
    lam = (type(lam) == 'number' and lam > 0.0) and lam or 0.0

    local beta = (alt > 0.0) and (b / alt) or 0.0
    local eps  = (alt > 0.0) and (lam / alt) or 0.0
    local d    = 1.0 - rho

    -- vTop IS THE RELEASE SPEED AS A FRACTION OF CRUISE, and at the shipped
    -- numbers it is 1 - 3e-13. It is carried rather than assumed to be 1
    -- because it is what makes the inversion exact at theta = 0 for ANY
    -- e-folding height -- including a large one, where the crate really would
    -- leave the aircraft already slowing.
    local vTop, thetaB
    if eps > 0.0 and d > 0.0 then
        vTop   = 1.0 - d * math.exp(-(1.0 - beta) / eps)
        thetaB = (1.0 - beta) + eps * math.log(vTop / rho)
    else
        -- NO e-FOLD IS A STEP, NOT AN ERROR: cruise to the flare height, then
        -- the final rate. Ugly to watch and perfectly well defined, which is
        -- the right way round for a config value somebody has zeroed.
        vTop   = 1.0
        thetaB = 1.0 - beta
    end

    return {
        beta = beta, eps = eps, rho = rho, d = d,
        vTop = vTop, lnvTop = math.log(vTop),
        thetaB = thetaB,
        -- THE STRETCH: the whole fall in units of the reference fall alt/V. 1.0
        -- for a linear descent, 1.1485 at the shipped numbers.
        total = thetaB + beta / rho,
    }
end

--- How long a fall from `alt` really takes, in milliseconds.
---
--- `descentMs` TIMES THE STRETCH, and `descentMs` is now the CRUISE-RATE
--- REFERENCE rather than the length of the fall -- the time the crate would
--- take if it never slowed down. Holding it fixed is what holds the rate the
--- owner confirmed fixed; the tail is added on top.
--- @param cfg table|nil  BR.Config.Airdrop
--- @param alt number|nil defaults to cfg.altitude
--- @return number ms
function BR.AirdropFallMs(cfg, alt)
    cfg = cfg or BR.Config.Airdrop or {}
    if type(alt) ~= 'number' then alt = cfg.altitude end
    return (cfg.descentMs or 30000) * BR.AirdropFallShape(alt, cfg).total
end

--- How much of the ALTITUDE has been given up at `now`, 0 at the release and 1
--- at tLand.
---
--- THE SIBLING OF BR.AirdropProgress AND NOT A REPLACEMENT FOR IT. Progress is
--- how far through the TIME the fall is and stays linear, because that is what
--- the blip and the crate's slow turn are measured against. This is how far
--- through the HEIGHT it is, and since 2026-08-28 the two are different numbers:
--- halfway through the fall in seconds the crate is already 56% of the way down.
---
--- NORMALISED TO THE RECORD'S OWN SPAN, which is the property that makes this
--- safe on a record nobody solved `tLand` for. Whatever `tLand - tRelease` is,
--- the crate leaves at full altitude and touches down exactly on it; what the
--- span decides is the cruise rate, not whether the arithmetic lands. A record
--- built by hand with a short span is a faster drop with the same shape rather
--- than a crate that arrives early or hangs in the air.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil
--- @return number
function BR.AirdropFallen(rec, now, cfg)
    local u = BR.AirdropProgress(rec, now)
    if u <= 0.0 then return 0.0 end
    if u >= 1.0 then return 1.0 end

    local s = BR.AirdropFallShape(rec and rec.alt or 0.0, cfg)
    local theta = u * s.total

    if theta >= s.thetaB then
        -- THE FLARE: the last `slowHeight` metres, at the final rate, straight.
        return 1.0 - BR.Clamp(s.beta - s.rho * (theta - s.thetaB), 0.0, 1.0)
    end
    if s.eps <= 0.0 or s.d <= 0.0 then
        -- Linear, either because nothing asked for a flare or because nothing
        -- said how to spread one.
        return BR.Clamp(theta, 0.0, 1.0)
    end

    -- THE INVERSION. `L` is ln(m) computed directly rather than by taking a log
    -- of an exponential: at the release m is 4e-13 and the naive route would be
    -- exp() of a large negative number fed straight back into log(). It is
    -- bounded above by 1/rho, because this branch only ever runs below the
    -- flare boundary, so the exp() below cannot overflow either.
    local L   = (theta - 1.0 + s.beta) / s.eps - s.lnvTop
    local phi = 1.0 - theta
              + s.eps * (s.lnvTop + math.log(1.0 + s.d * math.exp(L)))
    return 1.0 - BR.Clamp(phi, 0.0, 1.0)
end

--- How fast the crate is falling at `now`, in metres a second.
---
--- READ BY NOTHING THAT DRAWS ANYTHING -- the descent is a position curve and
--- the client never integrates a speed. It exists because the owner's request
--- was a statement about SPEED, so the suite has to be able to ask about speed
--- directly rather than inferring it from two heights, and because /brairdrop
--- printing "15.0 m/s now, 3.8 m/s at touchdown" is the difference between the
--- flare being checkable from a chair and being a paragraph.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil
--- @return number m/s
function BR.AirdropSpeedAt(rec, now, cfg)
    if not BR.AirdropArmed(rec) then return 0.0 end
    local from = rec.tRelease or rec.tStart or 0.0
    local span = (rec.tLand or 0.0) - from
    if span <= 0.0 then return 0.0 end

    local alt = rec.alt or 0.0
    local s   = BR.AirdropFallShape(alt, cfg)
    local theta = BR.AirdropProgress(rec, now) * s.total

    local frac
    if theta >= s.thetaB then
        frac = s.rho
    elseif s.eps <= 0.0 or s.d <= 0.0 then
        frac = 1.0
    else
        frac = 1.0 / (1.0 + s.d
                      * math.exp((theta - 1.0 + s.beta) / s.eps - s.lnvTop))
    end

    -- alt * total / span IS THE CRUISE RATE, whatever the span happens to be:
    -- at the shipped numbers span is descentMs * total, so it reduces to
    -- alt / descentMs -- 15 m/s -- with the stretch cancelling itself out.
    return frac * alt * s.total * 1000.0 / span
end

--- Metres above the ground at `now`.
---
--- NOT LINEAR SINCE 2026-08-28. It cruises at `alt / descentMs`, decelerates
--- exponentially into the last few tens of metres and holds 25% of the cruise
--- rate for the final 25 feet -- see the fall-curve block above for the shape
--- and for why it is written in height rather than in time.
---
--- THE PURE FALL CURVE, and since 2026-08-23 the client no longer draws the
--- crate off it directly -- see BR.AirdropCrateZ below and the note on its two
--- anchors. It stays because it is the honest statement of "how far above its
--- landing point is it", which is what every predicate and every test about the
--- descent is really asking.
--- @param rec table|nil
--- @param now number
--- @param cfg table|nil
--- @return number
function BR.AirdropHeightAt(rec, now, cfg)
    if not rec then return 0.0 end
    return (rec.alt or 0.0) * (1.0 - BR.AirdropFallen(rec, now, cfg))
end

--- Where the crate actually is, as an ABSOLUTE z.
---
--- ═══ TWO ANCHORS, AND THAT IS THE WHOLE OF IT ═══
---
--- It LEAVES at `rec.gz + rec.alt` -- the POI's hand-authored height plus the
--- release altitude. Authored, so it is the same number on every machine with
--- nothing probed, and so an aircraft flying at `rec.gz + planeHeight` is
--- exactly `planeAltAbove` above the box on the frame it lets go, by
--- arithmetic rather than by luck.
---
--- It ARRIVES at `groundZ` -- the client's own probe of the surface it has to
--- come to rest on. That end has to be measured: the authored z is a landmark's
--- nominal height and the crate lands on whatever is really under (x, y),
--- rooftop included (see client/airdrop.lua's groundOf, and 835254d for what
--- happens when a height is chosen on an opinion instead).
---
--- BOTH ENDS USED TO BE THE PROBE, which is how a crate came to hang below the
--- Cargobob that dropped it: the aircraft flew off one number and the crate off
--- another, and they differ by however wrong config/map.lua's first-pass z is at
--- that POI. The release end now pays no error at all, and the landing end pays
--- all of it -- which is the right way round, because only one of those two
--- moments is watched from ten metres away.
---
--- A nil `groundZ` means "this client has no probe answer yet" and falls back to
--- the authored height, exactly as every other reader of `rec.gz` does.
---
--- THE INTERPOLATION IS THE FALL CURVE AND NOT THE CLOCK (2026-08-28). Both
--- anchors are unchanged and so is the straight line between them; what moved is
--- how fast the crate travels along it. Reading BR.AirdropProgress here instead
--- would draw a crate at a linear height while every predicate and every test
--- said it was somewhere else.
--- @param rec table|nil
--- @param now number
--- @param groundZ number|nil  absolute z of the surface under (rec.x, rec.y)
--- @param cfg table|nil
--- @return number
function BR.AirdropCrateZ(rec, now, groundZ, cfg)
    if not rec then return 0.0 end
    local releaseZ = (rec.gz or 0.0) + (rec.alt or 0.0)
    local gz = (type(groundZ) == 'number') and groundZ or (rec.gz or 0.0)
    return gz + (releaseZ - gz) * (1.0 - BR.AirdropFallen(rec, now, cfg))
end

-- ---------------------------------------------------------------------------
-- The plane
-- ---------------------------------------------------------------------------

--- Is the delivery plane in the world at `now`?
---
--- From the announcement until `trailMs` after the release. Never longer: the
--- aircraft's job is over the moment the box leaves it, and one orbiting the
--- drop is scenery arguing with the fight underneath it.
---
--- IT USED TO GO HALF A MINUTE BEFORE THE CRATE LANDED, THEN WITH IT, AND NOW
--- IT GOES TWO SECONDS BEFORE. `descentMs` was halved to 15000 on 2026-08-23
--- ("make the loot drop 2x the speed") and `planeTrailMs` is 15000, so for five
--- days the two windows closed on the same instant. The 2026-08-28 flare added
--- 2.2s to the FALL and nothing to the trail, so the aircraft now leaves with
--- the crate 8.5m up and doing 4.9 m/s.
---
--- THAT IS LEFT ALONE ON PURPOSE. By then the Cargobob is 675m away and 250m up
--- -- nothing here ever depended on the order -- and following the fall would
--- mean deriving a trail window from a descent curve, which is a config number
--- the owner set becoming a thing that moves when an unrelated one does. The
--- suite asserts the new ordering rather than the old coincidence, so it is
--- still a change somebody has to look at.
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
-- ...AND WHAT IS UNDER IT, ANSWERED ONCE, OUT OF THE MAP FILE
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-23, testing 56c0ba7 -- which already contained the first
-- attempt at this: "Seems we've not landed on a way to stop the cargobob from
-- flying through the terrain? On 56c0ba7 it's definitely still doing that...
-- We need to get the Z for each coord where the drop is happening, fly the
-- cargobob 250m above that, and drop all flares and loot at the same time as
-- soon as it flies over the point. Not sure why it's that hard."
--
-- ═══ WHY THE FIRST ATTEMPT FAILED, WHICH HAD TO BE ANSWERED BEFORE ANYTHING
--     REPLACED IT ═══
--
-- bff7922 probed a CORRIDOR: eight GetGroundZFor_3dCoord samples spread over
-- the `planeLookAheadMs` of flight still ahead of the aircraft, lifting it
-- `planeTerrainClearance` above the highest answer, failing open when nothing
-- answered. The arithmetic was right. Two facts about WHERE it was asking kill
-- it anyway, and they compound into a feature that could never fire.
--
--   1. THE PROBE ONLY ANSWERS FOR TERRAIN THIS CLIENT HAS STREAMED, and the
--      aircraft spends its run-in over ground nobody is standing on. The run-in
--      is planeSpeed * planeLeadMs = 540m long, the corridor looked 270m
--      further ahead again, and the only player a drop is guaranteed to have is
--      within `armWithin` -- 200m -- of the drop point. So for the first half
--      of every pass it was asking about ground up to 810m away from the one
--      person who could have made it answer. Every sample failed, `top` stayed
--      nil, and BR.AirdropPlaneZ returned the nominal height. The fail-open
--      path was not the rare case it was written for; it was the flight.
--
--   2. AND THE CLIP GUARANTEED THAT WHAT IT COULD ANSWER FOR NEEDED NO LIFT.
--      The corridor was clipped inclusively at tRelease, and the commit message
--      presented that as the feature: "it collapses onto the drop point as the
--      release arrives". It does. The drop point is an authored street-level
--      POI, and it is the LOWEST point on the route by construction. So the
--      corridor only came inside streaming range as it shrank onto the one
--      place with nothing to clear. The window in which the probe could see and
--      the window in which it had something to say never overlapped.
--
-- There was no third bug under those two. Nothing was mis-applied, nothing
-- raced, and the height really was written to the entity the aircraft follows.
-- The answer was "nothing to clear" on every frame it ran, and it was wrong on
-- every frame it ran.
--
-- ═══ SO NOTHING IS PROBED FOR THIS AT ALL ANY MORE ═══
--
-- The owner's prescription is both simpler and the one that cannot fail this
-- way: resolve the ground at the drop point ONCE, fly a CONSTANT height above
-- it, and release everything the instant the aircraft is over the point.
--
-- The ground at the drop point is `rec.gz`, and `rec.gz` is the POI's
-- hand-authored z out of config/map.lua. It is not a measurement, and for THIS
-- job it does not need to be: it is in a file both ends already have, it is the
-- same number on every machine, and no amount of distance or streaming can stop
-- it answering. That is precisely the property the probe could not supply, and
-- it is why the drop point's height is taken from the map file while the
-- CRATE's landing height is still probed (see BR.AirdropCrateZ) -- the two
-- questions want opposite trade-offs and were being answered by one number.
--
-- ═══ AND A FLOOR IS STILL NEEDED. THAT IS A CHECKED CLAIM, NOT A WORRY ═══
--
-- A constant 250m over the DROP POINT is not 250m over everything the pass
-- crosses, and the map file can say by how much. Over all 128 authored POIs,
-- against a pass covering planeSpeed * (planeLeadMs + planeTrailMs) = 540m of
-- run-in plus 675m of trail, exactly two drop points have a HIGHER authored POI
-- inside that distance:
--
--   chiliad_ridge  z 400 -> flying 650, and `chiliad` (z 780) is 391m away.
--                  130m INSIDE the summit.
--   paleto         z  31 -> flying 281, and `chiliad_n` (z 320) is 304m away.
--                  39m inside it.
--
-- Two in 128 is rare, and it is also exactly the case the owner reported, so
-- the floor stays. What changes is where it comes from: the same authored
-- table, read once, rather than a probe read sixty times a second -- so the
-- floor is a pure function of the record and the config, identical on every
-- client, and it is known before the aircraft is built rather than discovered
-- while it flies.
--
-- WHAT THIS FLOOR CANNOT SEE is unnamed ground: a ridge with no POI on it is
-- not in the table and does not lift anything. That is a real limit and it is
-- stated rather than papered over -- but it is strictly better than the probe
-- it replaces, which could not see the named ground either.

--- The straight line of map this aircraft passes over, end to end.
---
--- BOTH ENDS OF THE WHOLE PASS, not a look-ahead. The old corridor deliberately
--- forgot the ground behind the aircraft, which was correct for a floor
--- recomputed every frame and is wrong for one solved once -- a height chosen
--- before takeoff has to cover everything the aircraft will ever be over.
---
--- AND IT INCLUDES THE TRAIL, which the old one only reached by accident. The
--- Cargobob keeps flying for `planeTrailMs` after the release: 675m at the
--- current numbers, further than the 540m run-in. Half the exposure was past
--- the drop point the whole time.
--- @param rec table|nil
--- @param cfg table|nil  BR.Config.Airdrop
--- @return number x1
--- @return number y1
--- @return number x2
--- @return number y2
function BR.AirdropRunIn(rec, cfg)
    if not rec then return 0.0, 0.0, 0.0, 0.0 end
    cfg = cfg or {}

    -- GTA forward for a heading: (-sin, cos). Same convention, same reason, as
    -- BR.AirdropPlaneAt and BR.AirdropOffsetAt -- and it has to be the same
    -- one, because this segment is where BR.AirdropPlaneAt will actually put
    -- the aircraft.
    local a = math.rad(rec.heading or 0.0)
    local fx, fy = -math.sin(a), math.cos(a)

    local sp   = cfg.planeSpeed or 45.0
    local back = sp * ((cfg.planeLeadMs or 12000) / 1000.0)
    local fwd  = sp * ((cfg.planeTrailMs or 15000) / 1000.0)
    local x, y = rec.x or 0.0, rec.y or 0.0

    return x - fx * back, y - fy * back, x + fx * fwd, y + fy * fwd
end

--- The highest AUTHORED ground the pass crosses, as an absolute z.
---
--- A POI counts when the flight line passes within its own radius plus
--- `planeCorridorPad`. The radius is the right measure and not a fixed number:
--- the authored z describes the ground across a named place, and lsia's 400m
--- disc really is 400m of z-20 tarmac while a 200m one is not.
---
--- nil MEANS "NOTHING NAMED IS NEAR THE ROUTE", which over most of this map is
--- the true answer and not a failure. There is no fail-open here to get wrong,
--- because there is nothing that can fail: the table is in memory.
--- @param rec table|nil
--- @param pois table|nil    BR.Config.Map.POIs
--- @param cfg table|nil     BR.Config.Airdrop
--- @return number|nil z     absolute, or nil
--- @return string|nil id    which POI it was, for the diagnostic
function BR.AirdropRunInTop(rec, pois, cfg)
    if not rec or type(pois) ~= 'table' then return nil end
    cfg = cfg or {}

    local pad = cfg.planeCorridorPad or 100.0
    local x1, y1, x2, y2 = BR.AirdropRunIn(rec, cfg)
    local dx, dy = x2 - x1, y2 - y1
    local len2 = dx * dx + dy * dy

    local top, id = nil, nil
    for _, p in ipairs(pois) do
        if type(p) == 'table'
           and type(p.x) == 'number' and type(p.y) == 'number' then
            -- Distance to the SEGMENT, not to the infinite line and not to the
            -- drop point: a summit half a kilometre off the bearing is not
            -- something this aircraft flies through, and lifting for it would
            -- be the permanent altitude increase this feature must not become.
            local t = 0.0
            if len2 > 0.0 then
                t = BR.Clamp(((p.x - x1) * dx + (p.y - y1) * dy) / len2,
                             0.0, 1.0)
            end
            if BR.Dist(p.x, p.y, x1 + dx * t, y1 + dy * t)
               <= (p.radius or 0.0) + pad then
                local z = p.z or 0.0
                if not top or z > top then top, id = z, p.id end
            end
        end
    end
    return top, id
end

--- The ONE height this aircraft flies at, absolute z, for the whole pass.
---
--- A CONSTANT (owner, 2026-08-23: "fly the cargobob 250m above that"). Solved
--- from the record and the map file, so it can be worked out before the
--- Cargobob exists and never has to be revisited -- which is the difference
--- between an aircraft that flies and one that steps upward whenever a probe
--- changes its mind.
--- @param rec table|nil
--- @param pois table|nil  BR.Config.Map.POIs
--- @param cfg table|nil   BR.Config.Airdrop
--- @return number z       absolute
--- @return string|nil id  the POI that raised it, or nil if nothing did
function BR.AirdropFlightZ(rec, pois, cfg)
    if not rec then return 0.0 end
    cfg = cfg or {}

    local nominal = (rec.gz or 0.0) + (cfg.planeHeight or 250.0)
    local top, id = BR.AirdropRunInTop(rec, pois, cfg)
    local z = BR.AirdropPlaneZ(nominal, top, cfg.planeTerrainClearance)
    if z <= nominal then return z, nil end
    return z, id
end

--- The higher of the flight plan and a floor under it.
---
--- UPWARD ONLY. `nominalZ` is what the drop wants and this can never lower it:
--- an aircraft that dipped toward a valley would arrive under the crate's
--- release height, and that height is the record's business and nobody else's.
---
--- A nil `floorZ` is "nothing to clear". It returns the nominal height, which
--- is what happens everywhere on this map except the two POIs named in the
--- block above.
--- @param nominalZ number     absolute z the flight plan wants
--- @param floorZ number|nil   highest ground under the pass, absolute
--- @param clearance number|nil  metres to hold above it
--- @return number z
function BR.AirdropPlaneZ(nominalZ, floorZ, clearance)
    if type(floorZ) ~= 'number' then return nominalZ end
    local floor = floorZ + (clearance or 60.0)
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
---
--- ON THE CLOCK AND NOT ON THE FALL CURVE, which is a choice and not an
--- oversight. The 2026-08-28 flare slowed the crate's DESCENT; the spin is a
--- fixed number of degrees spread over the fall to stop the box reading as a
--- prop on a rail, and taking it off BR.AirdropFallen would make it drift
--- through most of its arc in the first two thirds and creep through the rest.
--- Linear in time is the flourish that was asked for; nothing asked for the
--- rotation to slow down with the descent.
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
