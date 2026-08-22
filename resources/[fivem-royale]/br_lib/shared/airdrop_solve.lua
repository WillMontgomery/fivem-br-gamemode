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
---     heading,     -- the crate's resting heading
---     tStart,      -- server time the drop was committed and the blip appeared
---     tLand,       -- server time it touches down and bursts open
---   }
--- @param n integer
--- @param poi table    a BR.Config.Map.POIs entry
--- @param alt number
--- @param tStart number
--- @param tLand number
--- @param heading number|nil
--- @return table
function BR.BuildAirdropRecord(n, poi, alt, tStart, tLand, heading)
    return {
        n       = n,
        poi     = poi.id,
        x       = poi.x + 0.0,
        y       = poi.y + 0.0,
        gz      = (poi.z or 0.0) + 0.0,
        alt     = alt + 0.0,
        heading = (heading or 0.0) + 0.0,
        tStart  = tStart + 0.0,
        tLand   = tLand + 0.0,
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
--- slots pointing at it wraps, which is why two `exclusive` slots against a
--- one-item pool pay two Heavy Shields rather than nothing.
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
            }
        end
    end

    return out
end

-- ---------------------------------------------------------------------------
-- The descent
-- ---------------------------------------------------------------------------

--- How far through the fall, 0 at tStart and 1 at tLand.
--- @param rec table|nil
--- @param now number  server time
--- @return number
function BR.AirdropProgress(rec, now)
    if not rec then return 1.0 end
    local span = (rec.tLand or 0.0) - (rec.tStart or 0.0)
    if span <= 0.0 then return 1.0 end
    return BR.Clamp((now - rec.tStart) / span, 0.0, 1.0)
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
