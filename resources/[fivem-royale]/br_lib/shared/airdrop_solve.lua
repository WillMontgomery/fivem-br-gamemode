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
---     tLand,       -- server time it touches down and bursts open
---   }
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
    local out = {}

    -- HOW FAR FROM THE CENTRE A QUALIFYING POINT MAY BE, and the comparison
    -- below is the whole rule: `d <= reach` is "at least `margin` inside the
    -- rim", inclusive at both ends.
    --
    -- A NEGATIVE REACH NEEDS NO EARLY RETURN, and there was one here until the
    -- mutation pass showed it could not be killed. A distance is never
    -- negative, so `d <= reach` already refuses everything once the circle is
    -- narrower than the margin -- the guard was an optimisation that could
    -- never change an answer, and it also disagreed with the inclusive rule at
    -- exactly reach == 0: a POI standing on the centre of a circle whose radius
    -- IS the margin is exactly `margin` inside it, and therefore qualifies,
    -- for the same reason a POI exactly on the margin does anywhere else.
    local reach = (r or 0.0) - (margin or 0.0)

    for _, poi in ipairs(pois or {}) do
        if BR.Dist(poi.x, poi.y, cx, cy) <= reach then
            if not placeable or placeable(poi.x, poi.y) then
                out[#out + 1] = poi
            end
        end
    end
    return out
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
    local candidates = BR.AirdropSites(pois, cx, cy, r, margin, placeable)
    if #candidates == 0 then return nil, 0 end
    return rng:pick(candidates), #candidates
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
--- order, so the number of draws burned depends only on the config -- never on
--- what came out.
---
--- @param rng table
--- @param cfg table|nil  defaults to BR.Config.Airdrop
--- @return table[] stacks
function BR.AirdropPayout(rng, cfg)
    cfg = cfg or BR.Config.Airdrop
    local pools = cfg.resolvedPools or {}

    local decks, dealt = {}, {}
    local out = {}

    for _, name in ipairs(cfg.payout or {}) do
        local src = pools[name]
        if src and #src > 0 then
            local deck = decks[name]
            if not deck then
                deck = {}
                for i = 1, #src do deck[i] = src[i] end
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
    if not rec then return 1.0 end
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
    if not rec then return false end
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
    if not rec then return false end
    cfg = cfg or {}
    if now < (rec.tStart or 0.0) then return false end
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
    if not rec then return false end
    return now >= rec.tLand
end

--- Should the map blip be up?
---
--- From the moment the drop is announced until `lingerMs` after it lands
--- (owner: "The blip should only appear until 1 minute after the drop hits the
--- ground"). One expression, so the client's blip and any test of it cannot
--- disagree about the window.
--- @param rec table|nil
--- @param now number
--- @param lingerMs number|nil
--- @return boolean
function BR.AirdropBlipVisible(rec, now, lingerMs)
    if not rec then return false end
    if now < rec.tStart then return false end
    return now <= rec.tLand + (lingerMs or 60000)
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
--- @param lingerMs number|nil
--- @return boolean
function BR.AirdropExpired(rec, now, lingerMs)
    if not rec then return true end
    return now > (rec.tLand or 0.0) + (lingerMs or 60000)
end
