-- Storm solver.
--
-- The single most important property here: this is a PURE FUNCTION of a record
-- the server published once, plus the current time. Server and client both call
-- it and both get the same answer, so a shrinking storm costs zero per-frame
-- network traffic. The server uses it to apply damage; the client uses it to draw
-- the wall. Neither one streams the radius to the other.
--
-- Load order: requires enums.lua and geo.lua. storm_shape.lua is asked for at call
-- time only, so it may load either side of this file.

BR = BR or {}

--- The record shape published by the server (whole-table assignment only --
--- nested mutation of a state bag does not replicate):
---
---   {
---     phase   = 0,        -- 0 = pre-storm hold, 1..n = phase index
---     cx0, cy0, r0,       -- current circle
---     cx1, cy1, r1,       -- circle being shrunk toward
---     tStart,             -- server time this phase began
---     tWait,              -- ms held static before shrinking
---     tShrink,            -- ms spent interpolating
---     dps,                -- damage per second outside the circle
---     seed,               -- the match's storm seed: what SHAPE this is (#344)
---     mo,                 -- the wall's own outline when this record began, for
---                         --   the records that start part way through a morph;
---                         --   absent on every ordinary record
---   }
---
--- `seed` IS ON THE WIRE BECAUSE THE SHAPE CANNOT BE. Every zone is a random
--- shape now, the client draws the wall and the server does the damage, and
--- neither sends geometry -- so both derive the shape from this one integer plus
--- the zone index. See BR.StormZone below, which is the only spelling of that
--- derivation anywhere, and BR.StormShape.blobUnit, which is where it happens.
---
--- ═══ `mo` IS THE ONE EXCEPTION, AND IT IS A DEV PATH ═══
---
--- Phase p's wall starts as zone p-1 and morphs corner to corner into zone p across
--- the sweep, so an ordinary record starts as a zone -- which is what an absent
--- field reads as, and what every record but three is. `brstormfreeze` replaces a
--- record mid-sweep with one that holds the wall where it stands, its thaw re-enters
--- the phase from there, and a same-phase `brphase` does the same; all three start
--- from a wall that is NOT a zone but a moment of a morph. So they carry it:
---
---   mo = { t = <how far the morph had got>,
---          d = { x1, y1, r1, x2, y2, r2, ... },   -- every moving disc, world
---          b = { i1, i2, ... },                   -- the destination disc each
---                                                 --   one is travelling to
---          g = <how far a conjoined zone had grown> }   -- a freeze's only
---
--- -- the discs exactly, rather than the two circles they were computed from,
--- because a freeze of a thawed record is a morph of a morph, and only the discs
--- themselves compose. Each keeps its destination index, so a thaw and a same-phase
--- `brphase` resume every corner toward the corner it was heading for, without a
--- snap. (BR.StormMorphAt builds it.) `g` rides a freeze, which keeps the target, so
--- a zone frozen part way through growing into its destination neither shrinks back
--- to where it started nor grows the same ground twice.

--- How long a conjoined zone takes to grow into its destination, in ms: the
--- config's `grow.seconds`, and never longer than the hold it happens in, so the
--- growth is always over before the wall moves -- and a dev time scale that
--- shortens the hold shortens the growth with it. 0 is no growth: the old pop.
local function growMs(rec)
    local S = BR.Config and BR.Config.Storm
    local sec = S and S.grow and tonumber(S.grow.seconds) or 0.0
    local ms = sec * 1000.0
    local wait = rec.tWait or 0.0
    if wait < ms then ms = wait end
    return ms
end

--- How far a conjoined zone has grown at `elapsed` ms into its record: 0 at the
--- start of the hold, 1 once the growth window is over, and carried across a
--- freeze by `mo.g`. Pure, like everything else here -- the server's damage tick
--- and the client's wall read it off the same record and the same clock.
local function growthAt(rec, elapsed)
    local ms = growMs(rec)
    if ms <= 0.0 then return 1.0 end
    local g0 = (rec.mo and tonumber(rec.mo.g)) or 0.0
    return BR.Clamp(g0 + elapsed / ms, 0.0, 1.0)
end

--- Solve the storm at a given time.
---
--- @param rec table|nil   the published storm record
--- @param now number      server time in ms (BR.Clock.now())
--- @return number cx      current centre x
--- @return number cy      current centre y
--- @return number r       current radius
--- @return string state   one of BR.StormPhase
--- @return number msLeft  ms remaining in the current sub-phase
--- @return number dps     damage per second currently applied outside
--- @return number t       how far through the sweep: 0 holding, 1 finished --
---                        the same fraction the circle is interpolated by, and
---                        the one BR.StormZone moves every corner of the wall by
--- @return number g       how far a conjoined zone has grown into its destination
---                        (#344): 0 at the start of the hold, 1 once `grow.seconds`
---                        have passed -- always before the wall moves -- and read
---                        by BR.StormZone only on a phase whose destination
---                        overlaps the zone it starts in
function BR.StormAt(rec, now)
    if not rec then
        return 0.0, 0.0, 0.0, BR.StormPhase.PRE, 0.0, 0.0, 0.0, 1.0
    end

    local elapsed = now - rec.tStart
    local g = growthAt(rec, elapsed)

    -- Still holding: the next circle is already known and drawn on the map, so
    -- players can see where to rotate before the wall starts moving.
    --
    -- PHASE 1'S HOLD IS THE FREE-LOOT PERIOD AND DEALS NO DAMAGE ANYWHERE --
    -- the Fortnite rule: the whole map is safe until the first circle locks in
    -- and starts closing. The tour spans the entire map and the anchor rides
    -- one leg of it, so a far-end jumper can legitimately land kilometres
    -- outside circle 1; bleeding them for it before the wall has ever moved
    -- punishes the drop they were invited to make. From the first shrink
    -- onward -- including every LATER phase's hold -- outside always hurts.
    -- Decided HERE, in the solver, so the server's damage tick and the
    -- client's vignette cannot disagree about it.
    if elapsed < rec.tWait then
        local state = (rec.phase == 0) and BR.StormPhase.PRE or BR.StormPhase.HOLDING
        local dps = (rec.phase <= 1) and 0.0 or rec.dps
        return rec.cx0, rec.cy0, rec.r0, state, rec.tWait - elapsed, dps, 0.0, g
    end

    local shrinkElapsed = elapsed - rec.tWait

    -- Collapsed.
    if shrinkElapsed >= rec.tShrink then
        return rec.cx1, rec.cy1, rec.r1, BR.StormPhase.FINISHED, 0.0, rec.dps, 1.0, g
    end

    local t = shrinkElapsed / rec.tShrink

    return BR.Lerp(rec.cx0, rec.cx1, t),
           BR.Lerp(rec.cy0, rec.cy1, t),
           BR.Lerp(rec.r0,  rec.r1,  t),
           BR.StormPhase.SHRINKING,
           rec.tShrink - shrinkElapsed,
           rec.dps,
           t,
           g
end

--- THE SHAPE ONE ZONE WEARS, as a unit to be scaled by the solver's radius.
---
--- One line, and it is the reason the client's wall and the server's damage test
--- cannot disagree: both reach it, so there is no second spelling of "which shape
--- is this" to drift. The knobs live in config/storm.lua's `shape` block and a
--- corner count below three is the documented way back to circles.
---
--- ═══ A ZONE, NOT A PHASE ═══
---
--- Zone k is the zone phase k closes on, and zone 0 is the opening zone -- the map
--- disc. A record for phase p therefore holds TWO zones -- its wall starts as zone
--- p-1 and its target is zone p -- and BR.StormZone asks for both by their own
--- index. This used to be asked once, for the phase, and handed to both: the
--- moment the phase advanced, the circle the wall had just finished closing onto
--- re-rolled in place. That is the snap in #344's 2026-09-23 playtest, and it is
--- why the argument is a zone.
---
--- ═══ AND THE PHASES RIDE ALONG, BECAUSE THE ZONES ARE A CHAIN ═══
---
--- Zone z is drawn to fit inside zone z-1 at the ratio of their radii, so the
--- config's phase table is part of what a zone is. See BR.StormShape.blobUnit.
--- @param seed number|nil    the record's seed (server/storm.lua's seedRng)
--- @param zone number|nil    0 for the opening zone, k for phase k's target
--- @return table|nil unit
function BR.StormUnit(seed, zone)
    local S = BR.Config and BR.Config.Storm
    return BR.StormShape.blobUnit(seed, zone, S and S.shape, S and S.phases)
end

-- ═══ WHAT ONE RECORD'S MORPH IS MADE OF, WORKED OUT ONCE PER RECORD ═══
--
-- A record names two zones and where they stand, and everything the wall does
-- across the sweep follows from five lists: the discs the wall starts as (`src`),
-- the discs it has become by the knee (`mid`), where each of them ends (`dst`), the
-- index of that destination disc in the target zone's own list (`bi`), and the
-- target zone's discs as placed (`keep`). And one verdict: whether the target lies
-- ENTIRELY inside the zone the wall starts as -- by real shape, exactly
-- (BR.StormShape.fit), which is what BR.NextZoneCentre places every non-breakout
-- target to satisfy.
--
-- Held weakly per record, and re-derived if any field it was read from has moved
-- or a zone unit has been rebuilt: a record is whole-table-assigned everywhere in
-- the game, so this is a cache hit on every frame of a phase but the first.
local recInfo = setmetatable({}, { __mode = 'k' })

-- ═══ ONE MOVING ZONE, WHOSE SHAPE BECOMES THE DESTINATION'S BEFORE IT ARRIVES ═══
--
--   "the expectation is the shape of the outer (moving) circle will change at
--    runtime per frame to eventually match the shape of the inner
--    (stationary/destination) circle when it reaches, say, 15 seconds before
--    finishing the move."                                -- the owner, 2026-09-27
--
-- So a sweep has two legs, split at the KNEE: `morph.leadSeconds` before the sweep
-- ends (config/storm.lua) -- or later, where the destination has no room to be the
-- size the clock asks for there (see "where `mid` stands").
--
--   0 .. knee   every corner disc of the zone the wall leaves travels in a straight
--               line to its partner's disc of `mid` -- the DESTINATION'S OWN SHAPE,
--               placed a little larger than the destination and around it. The
--               outline changes every frame, and is the destination's by the knee.
--   knee .. 1   the wall IS the destination's shape, one fixed outline moved and
--               scaled onto the destination: every disc of `mid` travels straight
--               to its own disc of the destination, so the whole outline is one
--               similarity (BR.StormWallFrame), and it lands on the destination
--               exactly as the sweep ends.
--
-- WHERE `mid` STANDS. On a phase that did not break out the destination lies inside
-- the zone, and `mid` is the destination grown about a point inside it to THE SIZE
-- THE SWEEP'S CLOCK ASKS FOR AT THE KNEE -- read as the radius of a disc of its area,
-- which goes from the zone's to the destination's at one rate -- about the mean of
-- its corner centres where that fits in the zone the wall starts as, and otherwise
-- about the point of it nearest the edge it is pinned to. Where no point lets it grow
-- that far, it grows as far as fits and the KNEE MOVES LATER, to the instant the clock
-- asks for that size. midOf has the numbers and why (the 2026-09-28 jump). Three
-- things follow, and they are the three the one-leg morph before it had:
--
--   THE WALL HOLDS THE DESTINATION AT EVERY t. `mid` holds it (a convex set grown
--   about a point of itself holds itself), and the first leg's hull takes `mid`'s
--   discs in wherever they would poke out -- the wall RESTS on the grown destination
--   rather than cutting into it.
--
--   IT NEVER MOVES OUTWARD. Every moving disc heads in a straight line for a disc
--   that is in the hull for the rest of its leg -- `mid`'s in the first, the
--   destination's in the second -- so the wall at a later t is inside the wall at an
--   earlier one. Airdrop and rescue siting rest on that.
--
--   IT STARTS AND ENDS ON THE ZONES THEMSELVES. `mid` is inside the zone the wall
--   leaves, so adding it to that zone's hull changes nothing at t = 0; and the second
--   leg ends on the destination's discs.
--
-- On a BREAKOUT the destination is its own part of the safe zone and nothing has to
-- hold it: `mid` is the destination's shape on the solver's own circle at the knee,
-- and the zone is the wall union the destination (BR.StormZone), as it always was.
--
-- A DESTINATION OF NO RADIUS -- phase 8's point -- has no shape to take on. The last
-- zone shrinks onto its point in one leg, keeping its own shape, as it always did.
-- So does every sweep while `leadSeconds` is 0: one leg, the shape finishing only
-- as the wall arrives. That is the off switch.
--
-- THE KNEE DEPENDS ON HOW LONG THE SWEEP IS, and the sweep is priced on the wall
-- (BR.StormSweepPrice below): server/storm.lua prices it at the length it is about
-- to publish, and lengthens it until the two agree (its sweepSeconds).
local KNEE_MIN = 0.5        -- a sweep under twice the lead turns its shape half way
local MID_STEPS = 12        -- halvings of the grown destination's scale: 1/4096 of its range

--- Where the knee is ASKED to fall in a record's sweep, 0..1: `leadSeconds` before it
--- ends, and never before half way. nil for a sweep with one leg -- a destination of
--- no radius, a lead of 0 (the off switch), or a record with no sweep at all. midOf may
--- put it later; BR.StormKnee answers where it really is.
--- @param rec table
--- @return number|nil
local function kneeOf(rec)
    if (rec.r1 or 0.0) <= 0.0 then return nil end
    local S = BR.Config and BR.Config.Storm
    local lead = S and S.morph and tonumber(S.morph.leadSeconds) or 0.0
    local T = tonumber(rec.tShrink) or 0.0
    if lead <= 0.0 or T <= 0.0 then return nil end
    local k = 1.0 - lead * 1000.0 / T
    if k < KNEE_MIN then k = KNEE_MIN end
    return k
end

--- The source discs of a record: a morph's own discs when it carries one, and the
--- zone it starts as, paired with its target, otherwise.
local function sourceOf(rec, uA, uB)
    local src, bi = {}, {}
    local mo = rec.mo
    if mo then
        local d, b = mo.d or {}, mo.b or {}
        local nB = #uB.discs
        for i = 1, #b do
            local x, y, r = d[3 * i - 2], d[3 * i - 1], d[3 * i]
            if x and y and r then
                src[#src + 1] = { x = x, y = y, r = r }
                -- AN INDEX THE CURRENT UNIT DOES NOT HAVE -- a config edited under a
                -- frozen record -- travels to the target's first disc rather than
                -- to nothing.
                local k = math.tointeger(b[i]) or 1
                bi[#bi + 1] = (k >= 1 and k <= nB) and k or 1
            end
        end
        return src, bi
    end
    local ps = BR.StormShape.pairsOf(uA, uB)
    local cx, cy, r = rec.cx0, rec.cy0, rec.r0
    for i = 1, #ps do
        local p = ps[i]
        src[i] = { x = cx + r * p.a.x, y = cy + r * p.a.y, r = r * p.a.r }
        bi[i] = p.bi
    end
    return src, bi
end

--- `mid`, the destination's shape the first leg ends on, as one disc per moving disc
--- (the partner of the destination disc that one ends on), and the frame it stands
--- in: the destination's unit at (mx, my) scaled by `ms`. See the section note.
local function midOf(rec, e, knee)
    local SS = BR.StormShape
    local r1 = rec.r1
    local rk = BR.Lerp(rec.r0, r1, knee)
    local mx, my, ms
    if e.nested then
        local keep = e.keep
        local zks = SS.discHull(e.src)
        -- ═══ THE SIZE THE CLOCK ASKS FOR AT THE KNEE, BY AREA ═══
        --
        -- The zone's size is read as the radius of a disc of its own area, R, and the
        -- sweep takes R from the zone it leaves to the destination's at one rate: R(t) =
        -- R0 + t (R1 - R0). `mid` is the destination grown by lam, whose R is lam R1, so
        -- the clock asks lam = R(knee) / R1. By area rather than by the solver circle's
        -- radius because the opening zone is an exact disc and every other zone holds
        -- 0.9 of its circle: read by the circle, phase 1's first leg ran 1.2 to 1.7 times
        -- as fast as its second.
        local dks = SS.discHull(keep)
        local R0 = zks and math.sqrt(SS.areaOf(zks) / math.pi) or rec.r0
        local R1 = dks and math.sqrt(SS.areaOf(dks) / math.pi) or r1
        local want = 1.0
        if R1 > 0.0 then want = math.max(1.0, BR.Lerp(R0, R1, knee) / R1) end

        --- The destination's discs relative to a point of it, (cx, cy).
        local function relTo(cx, cy)
            local rel = {}
            for k = 1, #keep do
                rel[k] = { x = keep[k].x - cx, y = keep[k].y - cy, r = keep[k].r }
            end
            return rel
        end
        --- Does the destination grown `lam` about (cx, cy) fit the zone the wall leaves?
        local function fits(c, lam)
            return (not zks) or SS.fit(zks, c.rel, c.x, c.y, lam) <= 0.0
        end
        --- The most it grows about (cx, cy) and still fits, up to `want`. At 1 it is the
        --- destination, which that zone holds -- the nesting verdict -- so the bisection
        --- always has a side that fits, and keeps to it.
        local function most(c, from)
            if fits(c, want) then return want end
            local lo, hi = from or 1.0, want
            for _ = 1, MID_STEPS do
                local m = 0.5 * (lo + hi)
                if fits(c, m) then lo = m else hi = m end
            end
            return lo
        end

        -- THE MEAN OF ITS CORNER CENTRES FIRST, which is where every destination with
        -- room around it grows from.
        local px, py = 0.0, 0.0
        for k = 1, #keep do px, py = px + keep[k].x, py + keep[k].y end
        px, py = px / #keep, py / #keep
        local pick = { x = px, y = py, rel = relTo(px, py) }
        local lam = want

        -- ═══ AND WHERE THAT DOES NOT FIT, THE POINT OF THE DESTINATION IT GROWS MOST
        --     FROM -- AND THE KNEE WAITS FOR THE SIZE THE CLOCK SAYS (2026-09-28) ═══
        --
        --   "at the first phase or two, the border jumped in size while moving, suddenly
        --    being maybe 10 seconds ahead of where it should have been."  -- the owner
        --
        -- A destination placed near the edge of the zone it sits in cannot grow about
        -- its own middle before it pokes out of that zone, so `mid` used to be clamped to
        -- the destination itself or near it: the first leg then did the whole sweep's
        -- travel by the knee and the second had nothing left to do. The zone arrived 14
        -- seconds early on 9 of 12 phase-2 sweeps measured, and its speed fell 25 to 80
        -- times at the knee -- a wall racing in and stopping dead is the jump. So:
        --
        --   1. Grown about the point of the destination nearest the edge it is pinned
        --      to, it keeps growing away from that edge -- still holding the destination
        --      (any point of a convex shape is a centre it grows about and still holds
        --      itself) and still inside the zone it leaves. Asked of the destination's
        --      corner centres, the points on their discs furthest from the middle, and
        --      the points half way out to them.
        --   2. Where even that is short of the size the clock asks at the knee, the knee
        --      moves LATER, to the moment the clock asks for the size it can have. The
        --      zone is then on its schedule at the knee, and the second leg moves at the
        --      solver circle's own rate; the shape finishes turning later than
        --      `leadSeconds` before the end, by exactly as long as the geometry demands.
        if not fits(pick, want) then
            -- THE DISCS THE DESTINATION IS PINNED BY are the ones nearest the zone's edge,
            -- and the centre it grows most about is by them: each of the three tightest
            -- discs' centre, its point furthest from the middle, the point half way out to
            -- it, and the point between the two tightest -- pinned on two sides. Ten
            -- candidates at most, because this runs once per record on the client too.
            local order = {}
            for k = 1, #keep do
                local q = keep[k]
                order[k] = { q = q, slack = zks and
                    (SS.hullDistance(zks, q.x, q.y) + q.r) or 0.0, k = k }
            end
            table.sort(order, function(a, b)
                if a.slack ~= b.slack then return a.slack > b.slack end
                return a.k < b.k
            end)
            local cands, outer = {}, {}
            for j = 1, math.min(3, #order) do
                local q = order[j].q
                local dx, dy = q.x - px, q.y - py
                local dl = math.sqrt(dx * dx + dy * dy)
                local ox, oy = q.x, q.y
                if dl > 1e-9 and q.r > 0.0 then
                    ox, oy = q.x + q.r * dx / dl, q.y + q.r * dy / dl
                end
                outer[j] = { x = ox, y = oy }
                cands[#cands + 1] = { x = ox, y = oy }
                cands[#cands + 1] = { x = q.x, y = q.y }
                cands[#cands + 1] = { x = 0.5 * (px + ox), y = 0.5 * (py + oy) }
            end
            if outer[2] then
                cands[#cands + 1] = { x = 0.5 * (outer[1].x + outer[2].x),
                                      y = 0.5 * (outer[1].y + outer[2].y) }
            end
            -- The candidate that fits at the size asked and is nearest the middle, or the
            -- one that grows most. Ties go to the earlier, so the answer is fixed.
            local near, nearD = nil, math.huge
            for _, c in ipairs(cands) do
                c.rel = relTo(c.x, c.y)
                if fits(c, want) then
                    local d = (c.x - px) ^ 2 + (c.y - py) ^ 2
                    if d < nearD then near, nearD = c, d end
                end
            end
            if near then
                pick = near
            else
                -- ONLY A CANDIDATE THAT FITS AT THE BEST SO FAR IS BISECTED, from there:
                -- this runs once per record, on the client too, and the owner reads
                -- hitches (a millisecond or two at worst, where bisecting every
                -- candidate from 1 cost up to fourteen).
                local best = most(pick)
                for _, c in ipairs(cands) do
                    if fits(c, best) then
                        local m = most(c, best)
                        if m > best then best, pick = m, c end
                    end
                end
                lam = best
                -- R(k) = lam R1, solved for k: the knee the clock allows this size at.
                if R0 > R1 then
                    knee = BR.Clamp((R0 - lam * R1) / (R0 - R1), knee, 1.0)
                end
            end
        end
        mx, my, ms = pick.x + lam * (rec.cx1 - pick.x), pick.y + lam * (rec.cy1 - pick.y),
            lam * r1
    else
        mx, my, ms = BR.Lerp(rec.cx0, rec.cx1, knee), BR.Lerp(rec.cy0, rec.cy1, knee), rk
    end
    local discs = e.uB.discs
    local mid = {}
    for i = 1, #e.src do
        local b = discs[e.bi[i]] or discs[1]
        mid[i] = { x = mx + ms * b.x, y = my + ms * b.y, r = ms * b.r }
    end
    return mid, mx, my, ms, knee
end

--- The record's morph, worked out: see the section note. nil for the off switch.
local function infoOf(rec)
    local uB = BR.StormUnit(rec.seed, rec.phase)
    if not uB then return nil end
    local uA = nil
    if not rec.mo then uA = BR.StormUnit(rec.seed, (rec.phase or 1) - 1) end
    local knee = kneeOf(rec)
    local e = recInfo[rec]
    if e and e.uA == uA and e.uB == uB and e.mo == rec.mo
        and e.phase == rec.phase and e.seed == rec.seed
        and e.cx0 == rec.cx0 and e.cy0 == rec.cy0 and e.r0 == rec.r0
        and e.cx1 == rec.cx1 and e.cy1 == rec.cy1 and e.r1 == rec.r1
        and e.knee0 == knee then
        return e
    end

    local SS = BR.StormShape
    local src, bi = sourceOf(rec, uA, uB)
    local r1 = ((rec.r1 or 0.0) > 0.0) and rec.r1 or 0.0
    local keep = {}
    if r1 > 0.0 then
        for k, d in ipairs(uB.discs) do
            keep[k] = { x = rec.cx1 + r1 * d.x, y = rec.cy1 + r1 * d.y, r = r1 * d.r }
        end
    else
        -- A TARGET OF NO RADIUS IS ONE POINT, whatever unit it was drawn with.
        keep[1] = { x = rec.cx1 + 0.0, y = rec.cy1 + 0.0, r = 0.0 }
    end
    local dst = {}
    for i = 1, #src do dst[i] = keep[bi[i]] or keep[1] end

    -- NESTED, BY REAL SHAPE. Every disc of the target inside the zone the wall starts
    -- as -- the hull of those discs is then inside it too, because it is convex.
    local zks = SS.discHull(src)
    local nested = zks ~= nil and SS.fit(zks, keep, 0.0, 0.0, 1.0) <= 0.0

    e = { uA = uA, uB = uB, mo = rec.mo, phase = rec.phase, seed = rec.seed,
          cx0 = rec.cx0, cy0 = rec.cy0, r0 = rec.r0,
          cx1 = rec.cx1, cy1 = rec.cy1, r1 = rec.r1,
          src = src, dst = dst, bi = bi, keep = keep, nested = nested, knee0 = knee }
    if knee and #src > 0 then
        local k
        e.mid, e.mx, e.my, e.ms, k = midOf(rec, e, knee)
        -- A KNEE THE GEOMETRY PUSHED TO THE END IS NO KNEE: one leg, onto the
        -- destination's own discs, which is what `mid` has become.
        if k < 1.0 - 1e-9 then
            e.knee = k
        else
            e.mid, e.mx, e.my, e.ms = nil, nil, nil, nil
        end
    end
    recInfo[rec] = e
    return e
end

--- The leg of the sweep `t` is on: the discs it runs from and to, how far along it,
--- and the discs a nested wall must hold on it. See the section note.
--- @return table from, table to, number u, table|nil keep
local function legOf(e, t)
    local k = e.knee
    if not k then return e.src, e.dst, t, e.nested and e.keep or nil end
    if t < k then return e.src, e.mid, t / k, e.nested and e.mid or nil end
    return e.mid, e.dst, (t - k) / (1.0 - k), e.nested and e.keep or nil
end

--- The moving wall's corner list at sweep fraction `t`, without the pieces.
local function hullAt(e, t)
    local from, to, u, keep = legOf(e, t)
    return BR.StormShape.morphHull(from, to, u, keep)
end

--- WHERE THIS RECORD'S KNEE REALLY FALLS, 0..1: `morph.leadSeconds` before the end --
--- never before half way -- or later, on a nested phase whose destination has too
--- little room to be its scheduled size there (see midOf). nil for a one-leg sweep.
--- The client's map and the suites read this rather than re-deriving it from the lead.
--- @param rec table
--- @return number|nil
function BR.StormKnee(rec)
    local e = rec and infoOf(rec)
    return e and e.knee or nil
end

--- Is this record's target inside the zone its wall starts as, by real shape?
---
--- True on every phase the server placed without a breakout (BR.NextZoneCentre),
--- and that is what the wall, the map and airdrop siting each read to know whether
--- the destination is a separate part of the safe zone or already inside it.
--- @param rec table
--- @return boolean
function BR.StormNested(rec)
    local e = rec and infoOf(rec)
    return e ~= nil and e.nested
end

--- Whether a record's destination OVERLAPS the zone its wall starts as without
--- being inside it -- the conjoined case, and the only one that grows -- and how far
--- it has to grow: S, the furthest any point of the destination is outside the zone.
---
--- ASKED ONCE PER RECORD, EXACTLY. The two shapes meet when the origin is inside
--- Z + (-D), which is a corner list (BR.StormShape.sumOf), so one signed distance
--- decides it. And D is the hull of its discs while the signed distance to Z is
--- convex, so the furthest point of D is at a disc: fitOf, the same maximum the
--- nesting test reads. A destination of no radius is a point and never grows; a
--- disjoint one is the far island the owner is content to see appear at once.
local function growthInfo(rec, e)
    if e.overlap ~= nil then return e.overlap, e.growS end
    local SS = BR.StormShape
    local over, S = false, 0.0
    if not e.nested and (rec.r1 or 0.0) > 0.0 then
        local zks, dks = SS.discHull(e.src), SS.discHull(e.keep)
        if zks and dks then
            over = SS.hullDistance(SS.sumOf(zks, SS.reflect(dks)), 0.0, 0.0) < 0.0
            if over then S = SS.fit(zks, e.keep, 0.0, 0.0, 1.0) end
        end
    end
    e.overlap, e.growS = over, S
    return over, S
end

--- Does this record's destination overlap, without nesting in, the zone its wall
--- starts as? Those are the phases whose safe zone GROWS into the destination
--- across the start of the hold instead of taking it all at once. See BR.StormZone.
--- @param rec table
--- @return boolean overlaps
--- @return number reach   metres the zone grows by across the whole growth
function BR.StormOverlaps(rec)
    local e = rec and infoOf(rec)
    if not e then return false, 0.0 end
    return growthInfo(rec, e)
end

--- The zone a record's wall starts as, placed at (cx, cy, r) -- the record's own
--- circle unless the caller names another. A morph's own outline when it carries
--- one (`mo`), and the zone before this phase's otherwise.
local function sourceShape(rec, e, cx, cy, r)
    if rec.mo then return BR.StormShape.discShape(e.src, cx, cy, r) end
    return BR.StormShape.blob(cx, cy, r, e.uA)
end

--- The zone a phase is entered FROM, before its record exists: the host the next
--- zone is placed inside (server/storm.lua's drawCentre).
---
--- The zone before this phase at (cx, cy, r) -- zone 0, the map disc, for phase 1
--- -- or the outline a freeze, a thaw or a same-phase `brphase` carried in `mo`.
--- @return table shape
function BR.StormHost(seed, phase, cx, cy, r, mo)
    if mo then
        local rec = { seed = seed, phase = phase, cx0 = cx, cy0 = cy, r0 = r,
                      cx1 = cx, cy1 = cy, r1 = 0.0, mo = mo }
        local e = infoOf(rec)
        if e then return BR.StormShape.discShape(e.src, cx, cy, r) end
    end
    local u = BR.StormUnit(seed, (phase or 1) - 1)
    if not u then return BR.StormShape.circle(cx, cy, r) end
    return BR.StormShape.blob(cx, cy, r, u)
end

--- THE DESTINATION, placed: zone `phase` at (cx1, cy1, r1). It never changes
--- during the phase -- not its shape, not its corners, not where it is.
---
--- A TARGET OF NO RADIUS is phase 8's final point, and it is the one-metre circle
--- every collapsed zone is (union2's header argues why a point is not a disc).
---
--- A FRESH SHAPE EVERY CALL, deliberately: blobUnion re-stamps the pieces of the
--- parts it is handed, so a cached target walked after a union would read the
--- union's arc lengths. Building one is a placement and a piece list.
--- @param rec table
--- @return table shape
function BR.StormTarget(rec)
    if not rec then return BR.StormShape.circle(0.0, 0.0, 0.0) end
    local r1 = rec.r1 or 0.0
    if r1 <= 0.0 then return BR.StormShape.circle(rec.cx1 or 0.0, rec.cy1 or 0.0, 0.0) end
    local u = BR.StormUnit(rec.seed, rec.phase)
    if not u then return BR.StormShape.circle(rec.cx1, rec.cy1, r1) end
    return BR.StormShape.blob(rec.cx1, rec.cy1, r1, u)
end

--- The wall of a record already worked out: see BR.StormWall. A moving wall is
--- built into `pool` when one is passed (storm_shape.lua's "a pool").
local function wallOf(rec, e, t, pool)
    if t <= 0.0 then return sourceShape(rec, e, rec.cx0, rec.cy0, rec.r0) end
    if t >= 1.0 then return BR.StormTarget(rec) end
    local from, to, u, keep = legOf(e, t)
    return BR.StormShape.morph(from, to, u, keep,
        BR.Lerp(rec.cx0, rec.cx1, t), BR.Lerp(rec.cy0, rec.cy1, t),
        BR.Lerp(rec.r0, rec.r1, t), pool)
end

--- THE MOVING WALL at sweep fraction `t`, and nothing else: the zone it started as
--- at 0, the destination at 1, and in between the hull of every corner disc on its
--- straight way to the destination's shape by the knee and then onto the
--- destination itself (BR.StormShape.morph, twice -- see "one moving zone" above).
---
--- ON A NESTED PHASE IT CONTAINS THE DESTINATION AT EVERY t and so it IS the safe
--- zone. On a breakout the safe zone is this UNION the destination -- BR.StormZone.
---
--- AT THE ENDS IT IS THE PLACED ZONES THEMSELVES, not hulls that equal them, so the
--- wall at the end of one sweep and at the start of the next hold are one shape to
--- the bit.
---
--- ═══ IT NEVER MOVES OUTWARD ON A NESTED PHASE, AND THAT IS WHAT SITING RESTS ON ═══
---
--- Every moving disc heads for a disc that stays in the hull for the rest of its leg
--- -- the grown destination's in the first, the destination's own in the second --
--- so the wall at a later t is inside the wall at an earlier one (storm_shape.lua's
--- morph section has the argument for one leg). A point that is inside
--- the wall at an instant is inside it at every earlier instant, and a point inside
--- the destination is inside it at every instant. BR.AirdropLandingCircles and
--- BR.RescueCircles are built on exactly that.
--- @param rec table
--- @param t number|nil   BR.StormAt's seventh answer; nil reads as 0
--- @return table shape
function BR.StormWall(rec, t)
    if not rec then return BR.StormShape.circle(0.0, 0.0, 0.0) end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local e = infoOf(rec)
    if not e then
        return BR.StormShape.circle(BR.Lerp(rec.cx0, rec.cx1, t),
            BR.Lerp(rec.cy0, rec.cy1, t), BR.Lerp(rec.r0, rec.r1, t))
    end
    return wallOf(rec, e, t)
end

--- THE SAFE ZONE at a solved moment: the moving wall, and the destination -- grown
--- into, on a conjoined phase, rather than taken at once.
---
--- ═══ THE ONE PLACE THE ZONE IS BUILT, WHICH IS WHAT MAKES THE WALL HONEST ═══
---
--- Three callers used to spell `BR.StormShape.union2(cx, cy, r, rec.cx1, rec.cy1,
--- rec.r1)` out by hand -- the client's wall, the client's HUD readout and the
--- server's damage tick. That was already three chances to disagree while the
--- shape was a circle, and it becomes a correctness hole the moment the shape is
--- DRAWN FROM A SEED (#344): a caller that forgot the unit would measure a circle
--- against a wall drawn as a blob, and the symptom is damage taken where the
--- curtain says it is safe. So the derivation lives here and the callers ask for
--- the zone rather than assembling one.
---
--- ═══ ONE MOVING ZONE BECOMES THE DESTINATION'S SHAPE, AND THE DESTINATION STANDS
---     STILL ═══
---
---   "I want the moving wall's corners and lines to move and change to match the
---    destination's. Nothing about the destination shape should ever change while
---    in motion."                                     -- the owner, 2026-09-23
---
--- `t` is how far through the sweep the solved circle is -- BR.StormAt's seventh
--- answer -- and the wall is BR.StormWall at that `t`: the destination's shape by the
--- knee, `morph.leadSeconds` before the end, and the destination itself at the end.
--- So the next record's hold starts from zone p again, at the same circle, in the
--- same shape: no snap, because there is nothing left to change. The wall, the HUD
--- and the damage tick all pass the `t` they solved, and they agree to the bit.
---
--- THE CIRCLE IS IMPLIED BY `t`. Every disc of the wall is on its own path between
--- the two placed zones, so `(cx, cy, r)` adds nothing the record and `t` do not
--- already say, and is read only for a record with no shape at all -- the pre-#344
--- off switch -- where the zone is still the two circles.
---
--- ═══ NESTED: THE WALL. A BREAKOUT: THE WALL UNION THE DESTINATION ═══
---
--- On every phase that did not break out the destination lies inside the zone the
--- wall starts as, by its real shape, and the wall holds it the whole way across --
--- so the wall is the safe zone, one closed loop. A breakout's destination is its
--- own part: stitched to the wall where they overlap (#356), two islands where they
--- do not, exactly as the union always was, so a player who reaches the destination
--- early is safe there (#328). A destination of no radius is phase 8's final point,
--- which is not a disc to reach and is not a part (union2's header argues why).
---
--- ═══ A CONJOINED DESTINATION IS GROWN INTO, NOT POPPED ON (#344) ═══
---
---   "if they're conjoined, today the border pops suddenly to cover the whole area.
---    instead it should grow over a period of 20s to include that new area instead
---    of popping."                                    -- the owner, 2026-09-23
---
--- On a phase whose destination overlaps the zone the wall starts in without being
--- inside it (BR.StormOverlaps), the safe zone across the hold's first
--- `grow.seconds` is that zone grown `g` of the way into the destination --
--- Z union (D intersect Z grown by g S) -- where S is how far the destination's
--- furthest point is outside Z (BR.StormShape.grown has the geometry, and why every
--- piece of it is exact). It starts as Z, where the last sweep left the wall, and
--- ends on Z union D exactly, so nothing pops at either end. The destination itself
--- never changes; it is only intersected. `g` is BR.StormAt's eighth answer, pure in
--- the record and the clock, so the wall, the HUD and the damage tick grow it
--- together. A DISJOINT destination is the far island, and appears at once: the
--- owner is content with that.
---
--- A NIL `g` READS AS 1, the whole union at once. A caller that was never taught to
--- pass it therefore bills and draws the old pop -- MORE safe ground, never less.
---
--- A GROWTH THAT CANNOT BE BUILT -- two boundaries touching in a way the crossing
--- finder refuses -- is the whole union too, for the same reason. The wall and the
--- damage tick both come through here, so even then they agree.
---
--- THE MAP DRAWS THIS ZONE AS A HOLD BEGINS -- `t` 0 and `g` 0, beside the
--- destination -- and fades it off as the sweep sets off: since 2026-10-04 the maps show
--- nothing that moves, and the 3D wall is the only picture of the zone in motion
--- (client/storm.lua's storm.map, config/storm.lua's `overlay.sweepFadeSec`).
---
--- @param rec table|nil    the published storm record
--- @param cx number        the CURRENT centre, as BR.StormAt reports it
--- @param cy number
--- @param r number         the CURRENT radius
--- @param t number|nil     how far through the sweep; nil reads as 0
--- @param g number|nil     how far a conjoined zone has grown; nil reads as 1
--- @param pool table|nil   BR.StormShape.newPool(): a moving wall that IS the zone
---                         is built into it (storm_shape.lua's "a pool"). Valid
---                         until the next build from the same pool. Only
---                         client/storm.lua's moving wall passes one.
--- @return table shape
function BR.StormZone(rec, cx, cy, r, t, g, pool)
    if not rec then
        return BR.StormShape.circle(cx or 0.0, cy or 0.0, r or 0.0)
    end
    local e = infoOf(rec)
    if not e then
        return BR.StormShape.union2(cx, cy, r, rec.cx1, rec.cy1, rec.r1)
    end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    -- THE POOL ONLY WHERE THE WALL IS THE WHOLE ANSWER. A breakout's zone is the
    -- wall stitched to the destination, and blobUnion re-stamps the pieces of the
    -- parts it is handed, so a pooled wall is never handed to it.
    local whole = e.nested or t >= 1.0 or (rec.r1 or 0.0) <= 0.0
    local wall = wallOf(rec, e, t, whole and pool or nil)
    if whole then return wall end
    local target = BR.StormTarget(rec)
    g = (g == nil) and 1.0 or BR.Clamp(g, 0.0, 1.0)
    if g < 1.0 and t <= 0.0 and wall.hull and target.hull then
        local over, S = growthInfo(rec, e)
        if over then
            local zone = BR.StormShape.grown(wall, target, S * g)
            if zone then return zone end
        end
    end
    return BR.StormShape.blobUnion(wall, target)
end

--- WHEN THE WALL IS ONE FIXED OUTLINE MOVED AND SCALED, and how: the frame it stands
--- in at sweep fraction `t`. nil while its shape is still changing.
---
--- The wall at `t` is the wall at any other `t'` of the same frame moved by (x - x')
--- and scaled by s / s' about the frame's point:
---
---   the second leg of a nested sweep   the destination's shape, standing in `mid`'s
---                                      frame at the knee and in its own at the end
---   the last zone onto its point       its own shape, shrinking about the point
---
--- It is the knee's own claim -- from the knee the wall IS the destination's outline --
--- in a form a test can hold the wall to (tools/test_shared.lua's storm.knee). The map
--- used to place its outline by it; since 2026-10-04 the maps show nothing that moves,
--- and the suite is what reads it. A BREAKOUT'S ZONE IS THE WALL UNION THE
--- DESTINATION, which is no one outline under any frame while the wall moves, so it has
--- none. `id` names the family.
--- @param rec table
--- @param t number
--- @return number|nil x, number y, number s, string id
function BR.StormWallFrame(rec, t)
    local e = rec and infoOf(rec)
    if not e or not e.nested then return nil end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local r1 = rec.r1 or 0.0
    if r1 <= 0.0 then
        -- A WALL SHRINKING ONTO A POINT IS ITS OWN OUTLINE SCALED ABOUT IT: every disc
        -- heads straight for the point.
        return rec.cx1, rec.cy1, 1.0 - t, 'point'
    end
    if e.knee then
        if t < e.knee then return nil end
        local u = (t - e.knee) / (1.0 - e.knee)
        return BR.Lerp(e.mx, rec.cx1, u), BR.Lerp(e.my, rec.cy1, u),
            BR.Lerp(e.ms, r1, u), 'leg2'
    end
    if t >= 1.0 then return rec.cx1, rec.cy1, r1, 'leg2' end
    return nil
end

--- The fastest any corner of the wall moves during this record's sweep, in metres
--- a second: the most any one disc travels plus the most its radius changes, over
--- the time its leg takes -- the faster of the two legs.
---
--- A corner travelling to a corner of a different shape moves further than a
--- circle's edge, (r0 - r1) / T, and one that turns its shape by the knee does it in
--- less than the whole sweep. The damage cushion does not price on a speed at all
--- (BR.StormCushionZones); this is the bound the tests hold every wall to, and the one
--- number to read when a reader wants one.
--- @param rec table
--- @return number metres per second
function BR.StormWallSpeed(rec)
    if not rec then return 0.0 end
    local T = math.max((rec.tShrink or 0.0) / 1000.0, 1.0)
    local e = infoOf(rec)
    if not e then return math.abs((rec.r0 or 0.0) - (rec.r1 or 0.0)) / T end
    local function fastest(from, to, secs)
        local best = 0.0
        for i = 1, #from do
            local a, b = from[i], to[i]
            local v = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) + math.abs(b.r - a.r)
            if v > best then best = v end
        end
        return best / secs
    end
    if not e.knee then return fastest(e.src, e.dst, T) end
    return math.max(fastest(e.src, e.mid, e.knee * T),
        fastest(e.mid, e.dst, (1.0 - e.knee) * T))
end

-- ═══ THE DAMAGE CUSHION'S 0.7 s OF TRAVEL IS THE ZONE ITSELF, 0.7 s EITHER SIDE ═══
--
-- server/storm.lua bills a player only once they are ten metres outside the safe
-- zone, and while the wall moved it added 0.7 s of travel on top -- (r0 - r1) / T, a
-- CIRCLE's edge speed -- because the tick, the 4 Hz position sample and the client's
-- own clock disagree by about that much at the knife edge.
--
-- TWO THINGS OUTRUN A CIRCLE'S EDGE NOW (#344). The morph moves every corner to its
-- own partner, so parts of the wall move two to four times that speed; and a
-- conjoined zone GROWS into its destination during the HOLD, where the rule added
-- nothing at all -- a front doing 70 m/s on average at phase 2 and 180 at worst, so a
-- client clock a tenth of a second ahead could show a player inside ground the
-- server had not grown to yet, and bill them for it.
--
-- SO THE CUSHION IS WHERE THE ZONE WAS AND WILL BE, rather than a speed: the zone
-- `ms` either side of the tick, whatever is moving and however fast that part of it
-- goes. For two concentric circles that is exactly the old 0.7 s of (r0 - r1) / T;
-- for a morph it is each stretch of wall's own travel, so a player beside a slow
-- stretch gets no more slack than they did; for a growth it is the front's. Built
-- once a tick, three zones where there was one, and only while something moves: a
-- finished sweep and a grown hold are the zone alone.
--- @param rec table
--- @param now number   server time, ms
--- @param ms number    how far either side
--- @return table zones  the zone `ms` before and after `now` -- empty while it stands still
function BR.StormCushionZones(rec, now, ms)
    local out = {}
    if not rec then return out end
    local _, _, _, st, _, _, _, g = BR.StormAt(rec, now)
    local moving = st == BR.StormPhase.SHRINKING
    if not moving and st == BR.StormPhase.HOLDING and g < 1.0 then
        moving = (BR.StormOverlaps(rec))
    end
    if not moving then return out end
    for _, at in ipairs({ now - ms, now + ms }) do
        local cx, cy, r, _, _, _, t, ga = BR.StormAt(rec, at)
        out[#out + 1] = BR.StormZone(rec, cx, cy, r, t, ga)
    end
    return out
end

-- ═══ THE SWEEP IS PRICED ON THE WALL'S OWN ARRIVAL, NOT ON A DISTANCE (#344) ═══
--
-- server/storm.lua prices every sweep for the furthest player's run -- the authored
-- `shrink` is only a ceiling -- so that "a straggler two kilometres out gets their
-- run". That promise is about the wall that will actually chase them.
--
-- WHILE THE WALL WAS A BLEND, THE DISTANCE WAS THE RUN, EXACTLY. (1 - t) Z0 + t D
-- holds (1 - t) P + t N for every P in Z0 and N in D, so a player running straight at
-- the destination's nearest point at d / T stood inside the blend at every instant.
-- (52a7caa priced the circle's distance -- next center less next radius -- which fell
-- short of the drawn shape's, so its own price setter was caught; the distance to the
-- real shape is #344's.)
--
-- THE MORPH DOES NOT HOLD THAT RUNNER. Every corner travels to ITS partner, which is
-- not the point of the destination nearest anybody, so parts of the wall arrive over
-- a player sooner than their distance says. The review of this round priced a phase-5
-- sweep by distance and knocked the runner it was priced for: 139 HP, running at
-- 9 m/s straight at the destination from the moment the wall set off. And since the
-- shape finishes turning at the knee rather than at the end, its corners cover their
-- paths in less than the sweep. So the price reads the wall, both legs of it:
--
--   run(P, Q) = the largest, over the sweep, of lo(t) / t
--
-- where lo(t) is how far along the straight line from P toward a point Q of the
-- destination the safe zone begins at sweep fraction t. A runner who covers
-- run(P, Q) metres per sweep keeps lo(t) behind them, so they are inside at every
-- instant; and on a nested phase so is a faster one, because they stand between that
-- point and the destination, the zone is convex and it holds the destination. It is
-- never less than the length of the line, which is lo(1).
--
-- TWO LINES, AND THE PRICE IS THE BETTER OF THEM: straight at the destination's
-- nearest point, and straight at its centre as far as its edge -- the two ways a
-- player runs at a destination, and the two the round's review measured. A player
-- standing on the very edge of the wall with the nearest point off to the side has a
-- line that runs along the wall, which the wall leaves at once; the line in toward
-- the centre does not.
--
-- ═══ A PLAYER ALREADY OUTSIDE IS HELD AS THE BLEND HELD THEM ═══
--
-- A player `e` meters outside the zone the phase starts in is in the storm already
-- and cannot be kept inside it. They used to be priced on the bare distance, and that
-- was a seam a millimeter wide: the morph can need 1.3 times the distance, so a
-- player 0.5 m out was priced 146 m short of one 0.5 mm in, and their run left them
-- 65 m out of the wall. That is the phase-5 runner above: the round's final review
-- found them 0.5 m out, still knocked for 136 HP. And the players the seam caught are
-- ordinary ones -- a 4 Hz sample of somebody riding the last sweep's wall lands
-- either side of it, the 10 m cushion bills nobody for their first ten meters, and
-- the last sweep's stragglers are who this price is for. Running at d / T, the blend
-- kept them within (1 - t) e of it, so the cushion covered every one who started
-- inside it. That is the promise now, on the wall itself: lo(t) is where the line
-- first comes within (1 - t) e of the safe zone -- the zone grown by that much, which
-- is every corner radius grown by it. At e = 0 it is the inside player's rule
-- exactly, so there is no seam; at t = 1 it is the destination's edge, so the run is
-- never less than the line; and on a nested phase a faster runner is held too,
-- because the grown zone is still convex and still holds the destination.
--
-- (That phase-5 runner is priced 634 m now, past the phase's 60 s ceiling, where no
-- price protects anybody. docs/match-math.md has how often a sweep reaches it.)
--
-- A BREAKOUT reads the same lines against the wall union the destination. There a
-- runner who outpaces the wall's front can be ahead of it in the gap; the price
-- covers the one who keeps with it, as the blend's did.
--
-- A LINE ACROSS A GAP is its own length. Where the straight run already crosses open
-- storm at the start of the sweep -- every line out of a disjoint breakout's zone,
-- and a line from a player on the zone's edge that heads out of it -- no pace keeps
-- the runner inside: they are in the storm from their first step until they reach
-- the destination, which is safe from the start. lo(t) / t asked of such a line only
-- measures how soon the wall behind them passes their starting point, and on a
-- player standing on an edge that retreats it read 279 m / 1e-4 of a sweep: 3.9
-- million metres (phase 6, seed 2051024, BR.Rng(259) -- the breakout audit's case,
-- pinned in tools/test_shared.lua's storm.gap). So such a line is priced at what it
-- can promise, the destination reached by the end of the sweep: its length.
--
-- READ AT 62 INSTANTS -- 48 even steps and 14 more in toward the start, where the
-- maximum sits whenever a corner sets off faster than the blend would -- with where
-- each line meets the zone found exactly (BR.StormShape.lineEntry), and the two best
-- local maxima of the players who could set the price refined by golden section.
--
-- (The numbers below were measured on the one-leg morph, before the knee. The promise
-- is re-asked of the two-leg wall by tools/test_storm.lua's price.run and
-- price.outside, and what the knee costs the pacing is in docs/match-math.md.)
--
-- MEASURED over 5,472 players across 280 sweeps of 40 matches, against the zone the
-- damage tick bills at 1,000 instants: a runner at the priced pace on the better line
-- is never more than 0.23 m outside on a nested phase, at half as fast again too; on
-- a breakout one who holds exactly to it can get up to 10 m ahead of the wall's front
-- into the gap, which the moving cushion covers. The run is longer than the distance
-- for 11.5% of players, 1.48 times it at the 99th percentile. Refining only the
-- players within PRICE_SLACK of the roughest gave the all-refined price in 320 lobbies
-- of 320. Pricing sixty players costs 18 ms on average and 74 at worst, once a phase,
-- on the server only -- the client never prices anything.
--
-- AND FOR PLAYERS ALREADY OUTSIDE, over 200 matches: 24 points of every sweep's start
-- zone pushed 0.5 m and 5 m out, each priced alone and run at 9 m/s straight at the
-- nearest point or the center. Not one was billed on the better line, where 6, 6, 5
-- and 3 sweeps of phases 2 to 5 billed one on the distance's price; on the nearest
-- point's line alone, the nested sweeps with a billed runner 0.5 m out fell from 69,
-- 66, 46 and 19 to 0, 3, 5 and 1, which is what a player just inside already saw.
local PRICE_STEPS = 48      -- even samples across the sweep
local PRICE_T0 = 1e-4       -- where the geometric run toward the start stops
local PRICE_TAIL = 0.7      -- its ratio
local PRICE_REFINE = 18     -- golden-section steps per refined maximum
local PRICE_TOL = 1e-3      -- metres: a line that comes this close has arrived
local PRICE_SLACK = 1.5     -- a player whose rough price is within this factor of the
                            -- lobby's roughest is refined before the price is set

--- The sweep fractions the price reads the wall at, ascending. Built once.
local priceTs = nil
local function priceTimes()
    if priceTs then return priceTs end
    local tail, t = {}, 1.0 / PRICE_STEPS
    while t * PRICE_TAIL > PRICE_T0 do
        t = t * PRICE_TAIL
        tail[#tail + 1] = t
    end
    local ts = {}
    for i = #tail, 1, -1 do ts[#ts + 1] = tail[i] end
    for k = 1, PRICE_STEPS do ts[#ts + 1] = k / PRICE_STEPS end
    priceTs = ts
    return ts
end

--- What the price keeps on a record: the wall's corner list at each sample, built on
--- first use, and the destination and the start zone it measures against.
local function priceOf(rec, e)
    local pr = e.price
    if pr then return pr end
    local SS = BR.StormShape
    local D = BR.StormTarget(rec)
    pr = { ks = {}, D = D,
           dks = (D.hull and D.hull.ks) or SS.discHull(D.discs or {}),
           zone0 = BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0, 0.0, 1.0),
           zks0 = SS.discHull(e.src),
           -- ON A BREAKOUT THE DESTINATION IS ITS OWN PART, and a line may reach it
           -- before it reaches the wall. A destination of no radius is no part.
           apart = (not e.nested) and (rec.r1 or 0.0) > 0.0 }
    e.price = pr
    return pr
end

--- Where along one line the safe zone begins, given the wall's corner list: no
--- further than `L`, where the line is inside the destination. `grow` is the margin a
--- player who started outside is allowed at this instant -- the zone grown by it,
--- which is every radius of both corner lists grown by it (lineEntry).
local function loAlong(pr, ks, px, py, ux, uy, L, grow)
    local SS = BR.StormShape
    local tol = PRICE_TOL + grow
    local s = SS.lineEntry(ks, px, py, ux, uy, tol)
    if pr.apart then
        local sd = SS.lineEntry(pr.dks, px, py, ux, uy, tol)
        if sd and (not s or sd < s) then s = sd end
    end
    if not s or s > L then s = L end
    return s
end

--- Does the straight run along this line cross open storm at the very start of the
--- sweep -- ground outside both the zone the wall starts as and the destination, by
--- more than the margin `out` a player who started outside is allowed? Only a
--- breakout's line can: a nested zone is convex and holds the player and the
--- destination both. See "a line across a gap" in the section note.
local function gappedAtStart(pr, px, py, ux, uy, L, out)
    if not pr.apart or not pr.zks0 then return false end
    local SS = BR.StormShape
    local tol = PRICE_TOL + out
    local qx, qy = px + ux * L, py + uy * L
    local spans = {}
    for _, ks in ipairs({ pr.zks0, pr.dks }) do
        local a = SS.lineEntry(ks, px, py, ux, uy, tol)
        if a and a <= L then
            local back = SS.lineEntry(ks, qx, qy, -ux, -uy, tol) or L
            spans[#spans + 1] = { a, L - back }
        end
    end
    table.sort(spans, function(p, q) return p[1] < q[1] end)
    local reach = 0.0
    for _, sp in ipairs(spans) do
        if sp[1] > reach + 1e-6 then return true end
        if sp[2] > reach then reach = sp[2] end
    end
    return reach < L - 1e-6
end

--- run(P, Q) for one line: from (px, py) along (ux, uy) to where it is inside the
--- destination, `L` metres on, for a player `out` m outside the zone the phase
--- starts in -- 0 inside it -- who is held to (1 - t) out of it. Refined when `refine`.
local function lineRun(e, pr, px, py, ux, uy, L, out, refine)
    local function wallAt(t) return hullAt(e, t) end
    local ts = priceTimes()
    local vals, best = {}, L
    for k = 1, #ts do
        local ks = pr.ks[k]
        if not ks then
            ks = wallAt(ts[k])
            pr.ks[k] = ks
        end
        vals[k] = loAlong(pr, ks, px, py, ux, uy, L, (1.0 - ts[k]) * out) / ts[k]
        if vals[k] > best then best = vals[k] end
    end
    if not refine then return best end

    -- THE TWO BEST LOCAL MAXIMA, refined. Ties go to the earlier sample, so the order
    -- the refinement runs in -- and so the answer -- is fixed.
    local peaks = {}
    for k = 1, #ts do
        local v = vals[k]
        if v > L and (k == 1 or v >= vals[k - 1]) and (k == #ts or v > vals[k + 1]) then
            peaks[#peaks + 1] = k
        end
    end
    table.sort(peaks, function(a, b)
        if vals[a] ~= vals[b] then return vals[a] > vals[b] end
        return a < b
    end)
    local g = 0.5 * (math.sqrt(5.0) - 1.0)
    local function f(t)
        return loAlong(pr, wallAt(t), px, py, ux, uy, L, (1.0 - t) * out) / t
    end
    for i = 1, math.min(2, #peaks) do
        local k = peaks[i]
        local a = (k > 1) and ts[k - 1] or 0.5 * ts[k]
        local b = ts[k + 1] or 1.0
        local c, h = b - g * (b - a), a + g * (b - a)
        local fc, fh = f(c), f(h)
        for _ = 1, PRICE_REFINE do
            if fc > fh then
                b, h, fh = h, c, fc
                c = b - g * (b - a)
                fc = f(c)
            else
                a, c, fc = c, h, fh
                h = a + g * (b - a)
                fh = f(h)
            end
        end
        if fc > best then best = fc end
        if fh > best then best = fh end
    end
    return best
end

--- run(P): the better of the two lines. See the section note.
local function runOf(rec, e, px, py, refine)
    local SS = BR.StormShape
    local pr = priceOf(rec, e)
    local r1 = rec.r1 or 0.0
    local d
    if r1 > 0.0 then d = SS.distance(pr.D, px, py) else d = BR.Dist(px, py, rec.cx1, rec.cy1) end
    if d <= 0.0 then return 0.0 end
    -- OUTSIDE THE ZONE THE PHASE STARTS IN, by this much: see the section note.
    local out = math.max(0.0, SS.distance(pr.zone0, px, py))

    -- STRAIGHT AT THE NEAREST POINT.
    local nx, ny = rec.cx1, rec.cy1
    if r1 > 0.0 then nx, ny = SS.pointAtArc(pr.D, SS.nearestArc(pr.D, px, py)) end
    local L = BR.Dist(px, py, nx, ny)
    if not (L > 0.0) then return d end
    local ux0, uy0 = (nx - px) / L, (ny - py) / L
    local best = L
    if not gappedAtStart(pr, px, py, ux0, uy0, L, out) then
        best = lineRun(e, pr, px, py, ux0, uy0, L, out, refine)
    end

    -- AND STRAIGHT AT THE CENTRE, as far as the destination's edge.
    local C = BR.Dist(px, py, rec.cx1, rec.cy1)
    if r1 > 0.0 and C > 0.0 then
        local ux, uy = (rec.cx1 - px) / C, (rec.cy1 - py) / C
        local Lc = SS.lineEntry(pr.dks, px, py, ux, uy, 0.0)
        if Lc and Lc > 0.0 and Lc < best then
            local v = Lc
            if not gappedAtStart(pr, px, py, ux, uy, Lc, out) then
                v = lineRun(e, pr, px, py, ux, uy, Lc, out, refine)
            end
            if v < best then best = v end
        end
    end
    return best
end

--- The metres per sweep a straight run from (px, py) to the destination must be
--- PRICED AT so that the wall never catches the runner: see the section note. 0
--- inside the destination. A player outside the zone the phase starts in is priced
--- so that they are never further outside than the blend would have left them.
--- @param rec table     a record for the phase being priced -- its tShrink is not read
--- @param px number
--- @param py number
--- @return number metres per sweep
function BR.StormSweepRun(rec, px, py)
    if not rec then return 0.0 end
    local e = infoOf(rec)
    if not e then
        -- THE PRE-#344 OFF SWITCH: two circles, and the blend's own answer.
        return math.max(0.0, BR.Dist(px, py, rec.cx1, rec.cy1) - (rec.r1 or 0.0))
    end
    return runOf(rec, e, px, py, true)
end

--- The furthest run in a lobby: the largest BR.StormSweepRun over `points`, which is
--- what server/storm.lua prices a sweep at.
---
--- REFINED ONLY WHERE IT CAN MATTER. Every player's price is read off the shared
--- samples first, and only those within PRICE_SLACK of the roughest are refined -- a
--- refinement builds the wall afresh at every instant it reads, and only the largest
--- answer sets the price.
--- @param rec table
--- @param points table   { { x, y }, ... }
--- @return number metres per sweep
function BR.StormSweepPrice(rec, points)
    local best = 0.0
    if not rec then return best end
    local e = infoOf(rec)
    local rough, top = {}, 0.0
    for i = 1, #points do
        local p = points[i]
        if e then rough[i] = runOf(rec, e, p.x, p.y, false)
        else rough[i] = BR.StormSweepRun(rec, p.x, p.y) end
        if rough[i] > top then top = rough[i] end
    end
    for i = 1, #points do
        local v = rough[i]
        if e and v > 0.0 and v * PRICE_SLACK >= top then
            v = runOf(rec, e, points[i].x, points[i].y, true)
        end
        if v > best then best = v end
    end
    return best
end

--- HOW LONG A SWEEP IS, priced on the wall it will be: seconds, and the run it was
--- priced for.
---
--- The price is metres per sweep, and the wall it reads turns into the destination's
--- shape `morph.leadSeconds` before the sweep ends -- so the wall at a fraction of the
--- sweep, and the price with it, depends on the length the price sets. This starts at
--- the shortest sweep, whose knee is earliest and whose corners are fastest, prices a
--- record of that length (`probeFor(seconds)`), and lengthens it to what that price
--- asks for until the price read at a length asks for no more than that length --
--- the length and the wall it was priced on are then the ones published. It only ever
--- lengthens, and stops at the ceiling. MEASURED over 40 chains of placed zones, 240
--- sweeps: 161 were repriced after leaving the floor, and every published length was
--- one its own wall's price fits, or the ceiling (tools/test_shared.lua's storm.gap).
--- Pricing twice costs twice: 18 ms a phase on average becomes about 36, server only.
--- @param probeFor function   seconds -> a record of this phase with that sweep
--- @param points table        { { x, y }, ... }
--- @param pace number         metres per second
--- @param minS number         the shortest sweep, seconds
--- @param maxS number         the longest, seconds
--- @return number seconds, number metres per sweep
local SWEEP_ROUNDS = 4
function BR.StormSweepSeconds(probeFor, points, pace, minS, maxS)
    local sec = minS
    if maxS < sec then sec = maxS end
    local run = 0.0
    for _ = 1, SWEEP_ROUNDS do
        run = BR.StormSweepPrice(probeFor(sec), points)
        local want = BR.Clamp(run / pace, minS, maxS)
        if want <= sec then return sec, run end
        sec = want
    end
    return sec, run
end

--- THE WALL AT SWEEP FRACTION `t`, AS A RECORD CAN CARRY IT: the `mo` a freeze, a
--- thaw or a same-phase `brphase` starts its record from. See the record's header.
---
--- nil for a record still holding in the zone it started as, because a record built
--- from that zone's circle starts as that zone anyway. Otherwise every moving disc at
--- `t` with the destination disc it is heading for -- and, on a nested phase, the
--- discs the wall rests on in that leg too (the grown destination's before the knee,
--- the destination's own after it), because they are part of the wall's hull and
--- part of what the next record's morph must keep. Exact duplicates are dropped, so a
--- chain of freezes does not grow what it carries by the discs it already has.
---
--- `g`, THE GROWTH, RIDES ALONG WHEN IT IS PASSED, on a conjoined record -- and then
--- even in the hold, so a freeze part way through growing into the destination, and
--- the thaw after it, carry on from where the zone had got to rather than shrinking
--- back to where it started (BR.StormZone). Only a caller that keeps the target
--- passes it: brstormfreeze's freeze does; its thaw and a same-phase `brphase`, which
--- draw a new target with its own growth ahead of it, do not.
--- @param rec table
--- @param t number|nil
--- @param g number|nil   BR.StormAt's eighth answer, for a caller keeping the target
--- @return table|nil mo
function BR.StormMorphAt(rec, t, g)
    if not rec then return nil end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local e = infoOf(rec)
    local carry = (g ~= nil and e ~= nil) and (growthInfo(rec, e)) or false
    if t <= 0.0 and not rec.mo and not carry then return nil end
    if not e then return nil end
    local d, b, seen = {}, {}, {}
    local function add(x, y, r, i)
        local key = ('%a|%a|%a|%d'):format(x, y, r, i)
        if seen[key] then return end
        seen[key] = true
        d[#d + 1], d[#d + 2], d[#d + 3] = x, y, r
        b[#b + 1] = i
    end
    local from, to, u, keep = legOf(e, t)
    local s = 1.0 - u
    for i = 1, #e.src do
        local a, q = from[i], to[i]
        if t >= 1.0 then
            q = e.dst[i]
            add(q.x, q.y, q.r, e.bi[i])
        elseif t <= 0.0 then
            a = e.src[i]
            add(a.x, a.y, a.r, e.bi[i])
        else
            add(s * a.x + u * q.x, s * a.y + u * q.y, s * a.r + u * q.r, e.bi[i])
        end
    end
    -- ON A NESTED PHASE, WHAT THE WALL RESTS ON THIS LEG: the grown destination before
    -- the knee, each disc heading for the destination disc its partner is; the
    -- destination itself after it.
    if e.nested and t > 0.0 then
        if keep == e.mid and t < 1.0 then
            for i = 1, #e.mid do
                local q = e.mid[i]
                add(q.x, q.y, q.r, e.bi[i])
            end
        else
            for k = 1, #e.keep do
                local q = e.keep[k]
                add(q.x, q.y, q.r, k)
            end
        end
    end
    local mo = { t = t, d = d, b = b }
    if carry then mo.g = BR.Clamp(g, 0.0, 1.0) end
    return mo
end

-- The defaults a share or a line that cannot be used falls back to: the shipped
-- anchorRegion values in config/storm.lua, spelled again here because the value
-- being replaced may BE the config's. test_shared.lua's storm.anchor.region holds
-- the two spellings to each other by what the picker does with a NaN.
local ANCHOR_CITY_MAX_Y = 1050.0
local ANCHOR_CITY_SHARE = 0.62

--- Whether `y` is a line on the map: a number, not NaN, strictly inside the
--- storm's mapAABB (and finite, wherever no AABB is configured).
--- @param y any
--- @return boolean
local function lineOnMap(y)
    if type(y) ~= 'number' or y ~= y or y == math.huge or y == -math.huge then
        return false
    end
    local A = BR.Config and BR.Config.Storm and BR.Config.Storm.mapAABB
    if A and A.min and A.max then return y > A.min.y and y < A.max.y end
    return true
end

--- THE CITY LINE (#381): a point is CITY when its y is below this, and COUNTY
--- otherwise -- the owner's "y = 1050". The config's anchorRegion.cityMaxY, or
--- the shipped value when that is not a y on the map, exactly as the anchor's
--- draw reads it (BR.PickStormAnchor). ONE SPELLING for everything that asks
--- "city or county": the anchor, and Control Tower's Power outage (#396).
--- @return number
function BR.StormCityLine()
    local S = BR.Config and BR.Config.Storm
    local region = S and S.anchorRegion
    local line = type(region) == 'table' and region.cityMaxY or nil
    if not lineOnMap(line) then line = ANCHOR_CITY_MAX_Y end
    return line
end

--- Pick the match anchor: the POI the whole storm sequence homes on.
---
--- The scheme (user-designed, 2026-08-02): one random waypoint of THIS match's
--- flight tour, then one random POI between band.min and band.max units of it.
--- Route-coupled -- the opening circle almost always contains a stretch of the
--- path players actually dropped along -- and POI-anchored, so the centre is
--- always a nameable place on land, never a point in the sea.
---
--- ═══ THE REGION IS DRAWN FIRST (#381) ═══
---
---   "What I want is 50% in the city and 50% in the county."
---                                                    -- owner, 2026-10-03
---
--- Left to the waypoint, the county won: legs 3 and 4 of every tour are north of
--- the city and two of the four leg-2 options are too, so a random waypoint was
--- county two times in three and the anchor followed it -- city 37% of the time
--- over all 192 tours. So when `region` is given, the region is drawn BEFORE
--- anything else -- city with probability cityShare -- and the waypoint and the
--- POI are then both drawn inside it. The ANCHOR's split is cityShare by
--- construction: the draw decides the region, and nothing after it can move the
--- anchor across the line. The anchor still comes off THIS tour's own waypoints,
--- so the opening circle stays on the flight path.
---
--- One line splits the map: a point is CITY when its y is below cityMaxY (the
--- owner's y = 1050), and COUNTY otherwise. Waypoints and POIs are sorted by the
--- same line.
---
--- THE ANCHOR'S SPLIT IS NOT THE MATCH'S. The owner's 50/50 is where matches
--- open and end, and circle 1 roams off the anchor (2.4 km at the median) and
--- the final zone off circle 1, both drifting back toward a point near 43% city
--- whatever the anchor did. So cityShare is
--- not 0.5: it is CALIBRATED so that circle 1 and the final zone each land in the
--- city about half the time, and the anchor is then city about 62% of the time.
--- config/storm.lua's anchorRegion has the measurement.
---
--- A SHARE OR A LINE THAT CANNOT BE USED TAKES THE DEFAULT, the shipped values
--- above: a share that is not a number in 0..1, and a line that is not a y on
--- the map (strictly inside the storm's mapAABB). NaN is a number, so a type
--- check passes it, and every comparison with it is false: a NaN share would
--- anchor every match in the county, and a NaN line would put every POI there.
---
--- FAILURE IS NOT AN OPTION HERE: this runs inside the WARMUP transition, and
--- an error would kill the match before it starts. So the band widens in steps
--- when a waypoint is POI-sparse (coastal leg-1 points, the Chiliad exits),
--- and the nearest POI is the final fallback. Some POI is always
--- returned as long as one exists. The region adds two more of the same:
---
---   * a tour with no waypoint in the drawn region uses the waypoint nearest
---     the line instead (no authored tour does today -- leg 1 is always city
---     and legs 3 and 4 are always county -- but the legs are config);
---   * a drawn region with no POI in it is drawn from the whole table, so the
---     match still opens, just not in that region -- and the side returned is
---     where the anchor really is, never the draw it missed.
---
--- @param rng table         a BR.Rng instance (server only)
--- @param waypoints table   the tour's authored waypoints, { {x, y}, ... }
--- @param pois table        candidate POIs, { {x, y, ...}, ... }
--- @param band table        { min, max, widenStep, widenMax }
--- @param region table|nil  { cityMaxY, cityShare }; nil skips the region draw
---                          and picks from the whole tour and the whole table
--- @return table|nil poi    the chosen POI (a reference into `pois`)
--- @return table|nil wp     the waypoint it was picked around
--- @return string|nil side  'city' or 'county': the side of the line the chosen
---                          POI is on; nil when no region was given
function BR.PickStormAnchor(rng, waypoints, pois, band, region)
    if #pois == 0 or #waypoints == 0 then return nil, nil, nil end

    local minD = band and band.min or 500.0
    local maxD = band and band.max or 1500.0
    local step = band and band.widenStep or 500.0
    local cap  = band and band.widenMax or 4000.0

    local wps, pool, line = waypoints, pois, nil

    -- A CONFIG TYPO MUST NOT KILL WARMUP. anchorRegion = 0.62 (a number where a
    -- table belongs) would index a number here; anything that is not a table is
    -- read as the shipped defaults instead.
    if region ~= nil and type(region) ~= 'table' then region = {} end
    if region then
        local share = region.cityShare
        if type(share) ~= 'number' or not (share >= 0.0 and share <= 1.0) then
            share = ANCHOR_CITY_SHARE
        end
        line = region.cityMaxY
        if not lineOnMap(line) then line = ANCHOR_CITY_MAX_Y end

        local wantCity = rng:float() < share

        local inSide = {}
        for _, p in ipairs(pois) do
            if (p.y < line) == wantCity then inSide[#inSide + 1] = p end
        end
        if #inSide > 0 then pool = inSide end

        local onSide, nearest, nearestD = {}, nil, math.huge
        for _, w in ipairs(waypoints) do
            if (w.y < line) == wantCity then
                onSide[#onSide + 1] = w
            else
                local d = math.abs(w.y - line)
                if d < nearestD then nearest, nearestD = w, d end
            end
        end
        if #onSide > 0 then
            wps = onSide
        else
            wps = { nearest or waypoints[1] }
        end
    end

    local wp = rng:pick(wps)

    -- THE SIDE IS READ OFF THE ANCHOR, not off the draw: the two agree whenever
    -- the drawn region has a POI, and when it has none the anchor came from the
    -- whole table and the log should say where it really is.
    local function sideOf(p)
        if not (line and p) then return nil end
        return (p.y < line) and 'city' or 'county'
    end

    while true do
        local candidates = {}
        for _, p in ipairs(pool) do
            local d = BR.Dist(wp.x, wp.y, p.x, p.y)
            if d >= minD and d <= maxD then
                candidates[#candidates + 1] = p
            end
        end
        if #candidates > 0 then
            local poi = rng:pick(candidates)
            return poi, wp, sideOf(poi)
        end
        if maxD >= cap then break end
        maxD = math.min(cap, maxD + step)
    end

    -- Nothing within widenMax of this waypoint. Take the nearest POI outright:
    -- a slightly off-band anchor is a shrug, no anchor is a dead match. Nearest
    -- IN THE REGION, so the fallback cannot undo the draw.
    local best, bestD = nil, math.huge
    for _, p in ipairs(pool) do
        local d = BR.Dist(wp.x, wp.y, p.x, p.y)
        if d < bestD then best, bestD = p, d end
    end
    return best, wp, sideOf(best)
end

--- The breakout budget for one phase, with the chance RAMPED by progress.
---
--- The first circle must never break out and the last should nearly always
--- (user call, 2026-08-06). The reason is that the opening circle is enormous
--- and already contains most of the map -- moving it outside itself asks
--- players to cross the whole island before they have a gun -- while the late
--- circles are small, everyone is armed, and a static circle is where a
--- passive player wins by having picked the right building.
---
--- Linear from chanceStart at phase 1 to chanceEnd at the last phase.
---
--- @param cfg table      BR.Config.Storm
--- @param phase integer  1-based phase being entered
--- @return table|nil     { chance, gapMax, minRadius } for NextZoneCentre
function BR.StormBreakoutFor(cfg, phase)
    local bo = cfg and cfg.breakout
    if not bo then return nil end

    local n = #(cfg.phases or {})
    local t = 1.0
    if n > 1 then
        t = BR.Clamp((phase - 1) / (n - 1), 0.0, 1.0)
    end

    local a = bo.chanceStart or 0.0
    local b = bo.chanceEnd or 0.0
    return {
        chance    = a + (b - a) * t,
        gapMax    = bo.gapMax,
        minRadius = bo.minRadius,
    }
end

--- The CEILING on a phase's sweep, in seconds: the authored `shrink`, lifted on a
--- phase that rolled a breakout -- by `shrinkFactor`, and by the real shapes' reach.
---
--- ═══ THE 2.5 WAS A RATIO OF CIRCLE RUNS ═══
---
--- `shrinkFactor` was sized for circles (2026-08-06): the furthest anyone standing in
--- the zone a phase starts in can be from a separated destination is its far rim to
--- the destination's near one, and with the centres at most r0 + r1 + gapMax * r0
--- apart that is never more than (2 + gapMax) * r0 -- the "three times" a nested run
--- that the config's comment argues from. The placement has measured the gap between
--- the SHAPES since #344, and a zone stretched up to 3:1 reaches further from its
--- centre than its circle did, on both sides of the gap: measured over 300 forced
--- breakouts a phase, the furthest run is 3.4 to 4.0 r0 at worst against the circle's
--- 2.5, and phase 5's ceiling -- which covered every circle breakout's furthest run --
--- fell short on 12 percent of them.
---
--- So the lift keeps the circle's proportion. W, how far the furthest point of the
--- zone the wall starts as lies outside the destination, is read off the real shapes
--- (BR.StormShape.fit, exact at every corner disc that is outside it), and where it
--- is longer than any circle breakout could have been the ceiling grows with it.
--- Never below shrink * shrinkFactor, so a breakout that stayed as close as a circle
--- could have is priced exactly as it always was, and a phase that did not roll one
--- keeps its authored ceiling. The pricing below the ceiling still decides how much of
--- it is used: a lobby near the destination gets a short sweep regardless.
--- @param cfg table        BR.Config.Storm
--- @param rec table        the phase's record (its tShrink is not read)
--- @param brokeOut boolean whether the placement rolled a breakout
--- @return number seconds
function BR.StormSweepCeiling(cfg, rec, brokeOut)
    local p = cfg and cfg.phases and rec and cfg.phases[rec.phase]
    local shrink = (p and p.shrink) or 0.0
    if not brokeOut then return shrink end
    local bo = cfg.breakout or {}
    local ceiling = shrink * (bo.shrinkFactor or 1.0)
    local e = infoOf(rec)
    -- THE PRE-#344 OFF SWITCH is two circles, and a circle never passes its own bound.
    if not e then return ceiling end
    local SS = BR.StormShape
    local dks = SS.discHull(e.keep)
    local circleRun = (2.0 + (bo.gapMax or 0.5)) * (rec.r0 or 0.0)
    if not dks or not (circleRun > 0.0) then return ceiling end
    local W = SS.fit(dks, e.src, 0.0, 0.0, 1.0)
    if W > circleRun then ceiling = ceiling * (W / circleRun) end
    return ceiling
end

-- Metres of clearance a nested placement keeps from touching the zone it is inside.
-- A millimetre: far below anything a player can see, and nine orders of magnitude
-- above the rounding in a signed distance -- so "is this record nested" is decided
-- the same way on both sides of the wire however the last bits of a sine fall, and
-- a destination is never classified at the one knife edge where it would be drawn
-- as a second boundary inside the wall.
local NEST_CLEAR = 1e-3

-- How many times each ray is bisected. A FIXED count, so both of a phase's placements
-- -- at warmup and at the phase itself -- stop on the same double.
local RAY_STEPS = 48

--- The zone a placement closes from, as the corner list its nesting is tested
--- against: the host's hull, or -- A CIRCLE HOST, a zone so small blob() made it
--- one -- its one disc.
local function hostHull(host, cx, cy, r0)
    local hks = host and host.hull and host.hull.ks
    if not hks then
        local d = host and host.discs and host.discs[1]
        hks = BR.StormShape.discHull({ { x = d and d.x or cx, y = d and d.y or cy, r = d and d.r or r0 } })
    end
    return hks
end

--- THE NEXT ZONE ABOUT ITS OWN CENTER, at its real size: its discs, or one point
--- for a zone of no radius.
local function zoneDiscs(unit, r1)
    local D0 = {}
    if unit and (r1 or 0.0) > 0.0 then
        for k, d in ipairs(unit.discs) do
            D0[k] = { x = d.x * r1, y = d.y * r1, r = d.r * r1 }
        end
    else
        D0[1] = { x = 0.0, y = 0.0, r = 0.0 }
    end
    return D0
end

--- Is (x, y) off the map a storm may close on: over water (BR.Config.Map's
--- rectangles) or outside the surveyed boundary? BR.NextZoneCentre's "AND NOT
--- OFF THE MAP" test, which says why both halves run -- and the test every
--- center Storm control places is held to (#396). No map config is nothing off it.
--- @param x number
--- @param y number
--- @return boolean
function BR.StormOffMap(x, y)
    local M = BR.Config and BR.Config.Map
    if not M then return false end
    if M.IsWater and M.IsWater(x, y) then return true end
    if M.InBounds and not M.InBounds(x, y) then return true end
    return false
end

-- ═══ STORM CONTROL: EVERY LATER CIRCLE CLOSES TOWARD THE PICKED SPOT (#396) ═══
--
--   "this limitation should not exist. the next phases should instead work
--    towards the location the player selected."           -- owner, 2026-10-06
--
-- Round 4 refused a spot outside the next circle, near its edge or over water.
-- None of those is refused now: the storm goes as far toward ANY spot as the
-- planner's own rules let it, and ends on it when it can get there.
--
-- THE RULES ARE THE PLANNER'S, LESS ITS DICE (BR.NextZoneCentre), FOR EVERY
-- CIRCLE: each zone nested in the one before by its real shape (#344, the same
-- NEST_CLEAR), its exact bounding box inside the map bounds, and its center ON
-- THE MAP (BR.StormOffMap) -- the end's and every circle's between them alike.
-- No aimed phase breaks out or hugs the edge, and the city share (#381) is the
-- anchor's -- circle 1's, drawn before any Storm control can run -- so it never
-- applies here.
--
-- THE LAND, IN CONVEX PIECES. On the map -- inside the surveyed boundary and off
-- every water rectangle -- is not convex, so it is cut into convex pieces once
-- (landPieces), and every set of centers below is cut to them. A set no
-- coastline or water crosses is kept whole.
--
-- THE SPOT, ON LAND. A spot over water or off the surveyed map is aimed as the
-- nearest point to it on the map -- exactly: the nearest point of the nearest
-- piece (landNearest) -- the shore it was picked beside.
--
-- THE ROOMS. The centers a phase may take, as offsets from the center of the
-- zone before, are a convex ROOM: the zone before cut to chords (every chord
-- inside it, at most AIM_SAG of its radius in) and eroded by the next zone's
-- exact support, so every point of it truly nests.
--
-- WHERE THE STORM ENDS: the point nearest the spot that a chain of circles with
-- EVERY CENTER ON LAND can reach. Along a ROUTE -- which convex set of land each
-- phase's center stands in -- the centers a phase can reach are convex (the last
-- phase's plus its room, cut to the land), and so are the ends. A best-first
-- search over the routes (search) finds the one whose ends come nearest the
-- spot: no route ends nearer the spot than the land inside its centers plus the
-- rooms still to come, so the first route it finishes ends as near the spot as
-- any storm the rules allow can. The storm ends on the spot when that route
-- reaches it, and otherwise on its nearest point -- never outside the next circle
-- on the map, since every circle still fits inside the one before.
--
-- TOWARD, PHASE BY PHASE. Each circle's center is the point NEAREST THE SPOT
-- among the centers on land the rules allow it from the circle before AND from
-- which the storm can still end there over land (the backward reach on land: the
-- end less the next phase's room, cut to the land, and so on back, a union of
-- convex sets) -- so the walk closes on the spot as fast as the rules permit, and
-- every circle is as near it as any storm that still ends there could put it.
--
-- THE MAP BOUNDS, WHEREVER THEY CAN HOLD. The planner keeps a zone's box inside
-- mapAABB unless the zone before already overhangs it; here a zone is held to the
-- box from the first phase any placement of it fits there (a zone concentric in a
-- boxed one is boxed), and from the next such phase should no route on land fit
-- the box at that one.
--
-- DETERMINISTIC AND BOUNDED: no draw from any stream, fixed chord counts, every
-- step linear or n log n in the polygons' corners, at most AIM_OPEN_MAX routes
-- opened and AIM_SETS_MAX sets weighed a phase -- about 16 ms of server Lua for a
-- plan, 40 at the most measured, once per Storm control (BR.Storm.aim keeps the
-- plan on the match; enterPhase and Storm reveal read it). The land's pieces
-- cost about 2 ms, once.

-- How far a region's chords may sit inside the zone they were cut from: this
-- fraction of the zone's radius, and never under AIM_SAG_MIN meters. Every
-- region is that much inside the truth at worst, which is how close to the
-- planner's own rules the reach R is.
local AIM_SAG = 1e-4
local AIM_SAG_MIN = 0.01

-- The clearance every aimed zone keeps inside the one before: the planner's, and
-- five millimeters more, which absorbs the rounding of the polygons' corners and
-- the slack below.
local AIM_CLEAR = NEST_CLEAR + 5e-3

-- How far inside the reach the end is held when the walk to the exact end does
-- not pass the planner's tests -- an end on the reach's very edge, which only one
-- chain reaches -- and the slack each phase's backward reach is then drawn in by,
-- halved every phase, so no center balances on the edge of what still ends
-- there: two centimeters (pulled in toward the reach's middle, then drawn in all
-- round), and ten and a hundred times that where a walk needs it
-- (BR.StormAimPlan).
local AIM_SLACK = 0.02

-- How far the backward reach is grown when there is no slack to spare: a tenth
-- of a millimeter, so a reach that only touches the room is still a sliver and
-- not a rounding error.
local AIM_TAU = 1e-4

-- A point this close outside a polygon is in it.
local AIM_IN = 1e-7

-- Ends this much nearer the spot are no nearer: a micrometer, so a spot on a
-- piece's edge -- a coastline's tip -- is reached, not searched for forever.
local AIM_TIE = 1e-6

-- How many routes the search may open before it settles for the best end found
-- so far (`capped`; none found, the plain walk stands in): twice the most any
-- plan in tools/test_storm.lua's fuzz or round 5's review fuzz opens, and what
-- bounds the search's cost.
local AIM_OPEN_MAX = 256

-- How many convex sets of centers a phase of the walk may weigh: three times
-- the most any plan over the fuzz in tools/test_storm.lua needs, and what bounds
-- the walk's cost. Past it (`narrowed`) the walk weighs the ones nearest the
-- spot and the route the search found.
local AIM_SETS_MAX = 64

-- Twice the area, in square meters, a set of centers must keep to be searched on.
local AIM_AREA_MIN = 1e-6

-- How much of a set (twice the area, in square meters) the land may leave
-- uncovered and the set still count as wholly on land: rounding, nine orders
-- under anything the pieces' millimeter could hide.
local AIM_COVER = 1e-7

-- How far outside a half-plane a corner must be to cut it.
local AIM_HPI_EPS = 1e-9

--- Twice the signed area of a polygon (positive counter-clockwise).
local function polyArea2(xs, ys)
    local n, s = #xs, 0.0
    for i = 1, n do
        local j = (i % n) + 1
        s = s + xs[i] * ys[j] - xs[j] * ys[i]
    end
    return s
end

--- A polygon with its repeated corners dropped (and the last when it is the first).
local function polyTidy(xs, ys)
    local n = #xs
    if n < 2 then return xs, ys end
    local ox, oy, k = {}, {}, 0
    for i = 1, n do
        local x, y = xs[i], ys[i]
        if k == 0 or math.abs(x - ox[k]) > 1e-7 or math.abs(y - oy[k]) > 1e-7 then
            k = k + 1
            ox[k], oy[k] = x, y
        end
    end
    while k > 1 and math.abs(ox[k] - ox[1]) <= 1e-7 and math.abs(oy[k] - oy[1]) <= 1e-7 do
        ox[k], oy[k] = nil, nil
        k = k - 1
    end
    return ox, oy
end

--- The half-planes of a counter-clockwise convex polygon's edges, moved by
--- (ox, oy) and pushed out by `grow`, appended to `out`: { nx, ny, b, angle },
--- the points with nx * x + ny * y <= b.
local function polyLines(xs, ys, ox, oy, grow, out)
    local n = #xs
    for i = 1, n do
        local j = (i % n) + 1
        local ex, ey = xs[j] - xs[i], ys[j] - ys[i]
        local len = math.sqrt(ex * ex + ey * ey)
        if len > 1e-9 then
            local nx, ny = ey / len, -ex / len
            out[#out + 1] = { nx, ny, nx * (xs[i] + ox) + ny * (ys[i] + oy) + grow, math.atan(ny, nx) }
        end
    end
    return out
end

--- Where two lines meet; nil when they are parallel.
local function lineCut(a, b)
    local det = a[1] * b[2] - a[2] * b[1]
    if math.abs(det) < 1e-12 then return nil end
    return (a[3] * b[2] - b[3] * a[2]) / det, (a[1] * b[3] - b[1] * a[3]) / det
end

--- Do two lines face the same way, to within a nanoradian? Closer than that,
--- where they meet is rounding, so the tighter of the two stands for both.
local function lineSame(a, b)
    return math.abs(a[1] * b[2] - a[2] * b[1]) < 1e-9 and a[1] * b[1] + a[2] * b[2] > 0.0
end

--- Is (x, y) outside line l's half-plane?
local function lineOut(l, x, y)
    return l[1] * x + l[2] * y - l[3] > AIM_HPI_EPS
end

--- THE INTERSECTION OF HALF-PLANES, as a counter-clockwise polygon, or empty.
--- Sorted by angle and swept with a deque (the standard sort-and-sweep): n log n.
--- Every list handed to it is bounded -- each holds a closed polygon's edges.
local function polyHpi(L)
    table.sort(L, function(a, b) return a[4] < b[4] end)
    local dq, h, t = {}, 1, 0
    for i = 1, #L do
        local l = L[i]
        while t - h >= 1 do
            local x, y = lineCut(dq[t], dq[t - 1])
            if x and lineOut(l, x, y) then t = t - 1 else break end
        end
        while t - h >= 1 do
            local x, y = lineCut(dq[h], dq[h + 1])
            if x and lineOut(l, x, y) then h = h + 1 else break end
        end
        local last = (t >= h) and dq[t] or nil
        if last and lineSame(l, last) then
            -- THE SAME DIRECTION: the tighter of the two.
            if l[3] < last[3] then dq[t] = l end
        else
            t = t + 1
            dq[t] = l
        end
    end
    -- AND ACROSS THE WRAP: the last line and the first can be one direction too
    -- (angles of pi and -pi).
    while t - h >= 1 and lineSame(dq[t], dq[h]) do
        if dq[t][3] < dq[h][3] then dq[h] = dq[t] end
        t = t - 1
    end
    while t - h >= 2 do
        local x, y = lineCut(dq[t], dq[t - 1])
        if x and lineOut(dq[h], x, y) then t = t - 1 else break end
    end
    while t - h >= 2 do
        local x, y = lineCut(dq[h], dq[h + 1])
        if x and lineOut(dq[t], x, y) then h = h + 1 else break end
    end
    if t - h < 2 then return {}, {} end
    local xs, ys = {}, {}
    for i = h, t do
        local x, y = lineCut(dq[i], dq[(i < t) and (i + 1) or h])
        if x then xs[#xs + 1], ys[#ys + 1] = x, y end
    end
    xs, ys = polyTidy(xs, ys)
    -- An empty intersection can leave lines that do not close counter-clockwise.
    if #xs < 3 or polyArea2(xs, ys) <= 0.0 then return {}, {} end
    return xs, ys
end

--- The corner a convex polygon starts its Minkowski walk at: the lowest, then
--- the leftmost.
local function polyLowest(xs, ys)
    local k = 1
    for i = 2, #xs do
        if ys[i] < ys[k] or (ys[i] == ys[k] and xs[i] < xs[k]) then k = i end
    end
    return k
end

--- THE MINKOWSKI SUM of two counter-clockwise convex polygons (a point or a
--- segment included): their edges merged by angle from the two lowest corners.
local function polySum(axs, ays, bxs, bys)
    local na, nb = #axs, #bxs
    if na == 0 or nb == 0 then return {}, {} end
    local ia, ib = polyLowest(axs, ays), polyLowest(bxs, bys)
    local ox, oy, k = {}, {}, 0
    local i, j = 0, 0
    -- Every pass advances at least one walk on a proper polygon; the cap is for
    -- one rounding could stall. Repeated corners are dropped as they come.
    for _ = 1, 2 * (na + nb) + 4 do
        if i >= na and j >= nb then break end
        local pa, pb = ((ia + i - 1) % na) + 1, ((ib + j - 1) % nb) + 1
        local x, y = axs[pa] + bxs[pb], ays[pa] + bys[pb]
        if k == 0 or math.abs(x - ox[k]) > 1e-7 or math.abs(y - oy[k]) > 1e-7 then
            k = k + 1
            ox[k], oy[k] = x, y
        end
        local qa, qb = (pa % na) + 1, (pb % nb) + 1
        local cr = (axs[qa] - axs[pa]) * (bys[qb] - bys[pb]) - (ays[qa] - ays[pa]) * (bxs[qb] - bxs[pb])
        local stepA = cr >= 0.0 and i < na
        local stepB = cr <= 0.0 and j < nb
        if not stepA and not stepB then
            if i < na then stepA = true else stepB = true end
        end
        if stepA then i = i + 1 end
        if stepB then j = j + 1 end
    end
    while k > 1 and math.abs(ox[k] - ox[1]) <= 1e-7 and math.abs(oy[k] - oy[1]) <= 1e-7 do
        ox[k], oy[k] = nil, nil
        k = k - 1
    end
    return ox, oy
end

--- Is (x, y) in a counter-clockwise convex polygon, to `tol`?
local function polyInside(xs, ys, x, y, tol)
    local n = #xs
    if n == 0 then return false end
    if n == 1 then return (x - xs[1]) ^ 2 + (y - ys[1]) ^ 2 <= tol * tol end
    for i = 1, n do
        local j = (i % n) + 1
        local ex, ey = xs[j] - xs[i], ys[j] - ys[i]
        local len = math.sqrt(ex * ex + ey * ey)
        if len > 0.0 and ex * (y - ys[i]) - ey * (x - xs[i]) < -tol * len then return false end
    end
    return true
end

--- The point of a convex polygon nearest (x, y): itself when inside.
local function polyNearest(xs, ys, x, y)
    local n = #xs
    if n == 0 then return x, y end
    -- One pass: inside (no edge has the point on its right) and the nearest point
    -- of the outline.
    local inside = n >= 3
    local bx, by, bd = xs[1], ys[1], math.huge
    for i = 1, n do
        local j = (i % n) + 1
        local ax, ay = xs[i], ys[i]
        local ex, ey = xs[j] - ax, ys[j] - ay
        local px, py = x - ax, y - ay
        local L2 = ex * ex + ey * ey
        local t = 0.0
        if L2 > 0.0 then
            if inside and ex * py - ey * px < 0.0 then inside = false end
            t = (px * ex + py * ey) / L2
            if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
        end
        local qx, qy = ax + ex * t, ay + ey * t
        local dx, dy = qx - x, qy - y
        local d = dx * dx + dy * dy
        if d < bd then bx, by, bd = qx, qy, d end
    end
    if inside then return x, y end
    return bx, by
end

--- A convex polygon cut to one half-plane, nx * x + ny * y <= b
--- (Sutherland-Hodgman); the polygon itself when no corner is outside it.
local function clipHalf(xs, ys, nx, ny, b)
    local n = #xs
    if n == 0 then return xs, ys end
    local out = 0
    for i = 1, n do
        if nx * xs[i] + ny * ys[i] > b then out = out + 1 end
    end
    if out == 0 then return xs, ys end
    local ox, oy = {}, {}
    if out == n then return ox, oy end
    local px, py = xs[n], ys[n]
    local pd = nx * px + ny * py - b
    for i = 1, n do
        local x, y = xs[i], ys[i]
        local d = nx * x + ny * y - b
        if d <= 0.0 then
            if pd > 0.0 then
                local t = pd / (pd - d)
                ox[#ox + 1], oy[#oy + 1] = px + (x - px) * t, py + (y - py) * t
            end
            ox[#ox + 1], oy[#oy + 1] = x, y
        elseif pd <= 0.0 then
            local t = pd / (pd - d)
            ox[#ox + 1], oy[#oy + 1] = px + (x - px) * t, py + (y - py) * t
        end
        px, py, pd = x, y, d
    end
    return ox, oy
end

--- A convex polygon cut to every line of a list ({ nx, ny, b, ... } each).
local function clipBy(xs, ys, L)
    local x0, y0 = xs, ys
    for i = 1, #L do
        if #xs == 0 then break end
        local l = L[i]
        xs, ys = clipHalf(xs, ys, l[1], l[2], l[3])
    end
    if xs == x0 then return xs, ys end
    return polyTidy(xs, ys)
end

--- The distance from (x, y) to a convex polygon: zero inside it.
local function polyDist(xs, ys, x, y)
    local qx, qy = polyNearest(xs, ys, x, y)
    return math.sqrt((qx - x) ^ 2 + (qy - y) ^ 2)
end

--- A polygon's bounding box.
local function polyBox(xs, ys)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #xs do
        local x, y = xs[i], ys[i]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- The directions a set's reach is bounded in: AIM_DIRS of them, evenly round,
-- the four axes among them. Lines this far apart close a polygon at most
-- r * (1 / cos(pi / AIM_DIRS) - 1) outside a set of reach r: 20 cm at 2.6 km.
local AIM_DIRS = 256

-- Every how many of those directions the backward reach is cut to the forward
-- one: 32 lines, the four axes among them.
local AIM_LENS = 8
local DIR_C, DIR_S = {}, {}
for d = 1, AIM_DIRS do
    local a = (d - 1) * 2.0 * math.pi / AIM_DIRS
    DIR_C[d], DIR_S[d] = math.cos(a), math.sin(a)
end
DIR_C[AIM_DIRS // 4 + 1], DIR_S[AIM_DIRS // 4 + 1] = 0.0, 1.0
DIR_C[AIM_DIRS // 2 + 1], DIR_S[AIM_DIRS // 2 + 1] = -1.0, 0.0
DIR_C[3 * AIM_DIRS // 4 + 1], DIR_S[3 * AIM_DIRS // 4 + 1] = 0.0, -1.0
-- Each direction's opposite.
local OPPOSITE = {}
for d = 1, AIM_DIRS do OPPOSITE[d] = ((d - 1 + AIM_DIRS // 2) % AIM_DIRS) + 1 end

--- A counter-clockwise convex polygon's support in each of the AIM_DIRS
--- directions: its furthest corner along each, found turning with them.
local function supportsOf(xs, ys)
    local n = #xs
    local k, best = 1, -math.huge
    for i = 1, n do
        local v = DIR_C[1] * xs[i] + DIR_S[1] * ys[i]
        if v > best then k, best = i, v end
    end
    local h = {}
    for d = 1, AIM_DIRS do
        local c, s = DIR_C[d], DIR_S[d]
        local v = c * xs[k] + s * ys[k]
        for _ = 1, n do
            local j = (k % n) + 1
            local w = c * xs[j] + s * ys[j]
            if w > v then k, v = j, w else break end
        end
        h[d] = v
    end
    return h
end

--- The polygon the support lines `h` (one per direction) close -- every
--- `step`-th of them, all by default: around the set they bound, its corners
--- where each line meets the next.
local function supportPoly(h, step)
    step = step or 1
    local xs, ys = {}, {}
    local sn = math.sin(2.0 * math.pi * step / AIM_DIRS)
    for d = 1, AIM_DIRS, step do
        local e = ((d + step - 1) % AIM_DIRS) + 1
        xs[#xs + 1] = (h[d] * DIR_S[e] - h[e] * DIR_S[d]) / sn
        ys[#ys + 1] = (h[e] * DIR_C[d] - h[d] * DIR_C[e]) / sn
    end
    return polyTidy(xs, ys)
end

-- ═══ THE LAND, IN CONVEX PIECES ═══
--
-- What BR.StormOffMap calls on the map -- inside the surveyed boundary and off
-- every water rectangle -- cut into convex pieces: the boundary ear-clipped into
-- triangles, the triangles merged back wherever two make one convex piece
-- (Hertel-Mehlhorn), and every piece a water rectangle cuts split into the parts
-- of it beside the rectangle. Every piece keeps LAND_IN inside the coastline and
-- off the water, so a point in one is on the map with no rounding to argue
-- about; the pieces' union is the land, less that millimeter. Built once from
-- BR.Config.Map's own tables, and again whenever one of them is a new table.
-- No boundary loaded is no coastline: the land is then everything within
-- LAND_FAR of the map's middle, less the water.
local LAND_IN = 1e-3
local LAND_FAR = 1e5
local landCache = { b = false, w = false, pieces = nil }

--- The triangles of a simple counter-clockwise polygon, as corner indices:
--- ear clipping, a corner at a time.
local function earClip(px, py)
    local function cross(a, b, c)
        return (px[b] - px[a]) * (py[c] - py[a]) - (py[b] - py[a]) * (px[c] - px[a])
    end
    local idx, tris = {}, {}
    for i = 1, #px do idx[i] = i end
    while #idx > 3 do
        local m, cut = #idx, nil
        for k = 1, m do
            local a, b, c = idx[(k - 2) % m + 1], idx[k], idx[k % m + 1]
            if cross(a, b, c) > 0.0 then
                local ear = true
                for t = 1, m do
                    local v = idx[t]
                    if v ~= a and v ~= b and v ~= c
                        and cross(a, b, v) >= 0.0 and cross(b, c, v) >= 0.0 and cross(c, a, v) >= 0.0 then
                        ear = false
                        break
                    end
                end
                if ear then
                    cut = k
                    tris[#tris + 1] = { a, b, c }
                    break
                end
            end
        end
        if not cut then
            -- NO EAR LEFT: only a corner on a straight line can be, and it goes
            -- without a triangle.
            for k = 1, m do
                if math.abs(cross(idx[(k - 2) % m + 1], idx[k], idx[k % m + 1])) <= 1e-6 then
                    cut = k
                    break
                end
            end
            if not cut then break end
        end
        table.remove(idx, cut)
    end
    if #idx == 3 and cross(idx[1], idx[2], idx[3]) > 0.0 then tris[#tris + 1] = { idx[1], idx[2], idx[3] } end
    return tris
end

--- Triangles made fat: every diagonal two triangles share is flipped to the
--- quad's other one wherever that one is inside it and the fourth corner is
--- inside the first triangle's circumcircle (Lawson's flips, to the constrained
--- Delaunay triangulation) -- so no fan of slivers meets at one corner, and
--- the merge below has fat pieces to merge. The boundary's own edges belong to
--- one triangle each and never flip.
local function delaunayFlip(px, py, tris)
    local function cross(a, b, c)
        return (px[b] - px[a]) * (py[c] - py[a]) - (py[b] - py[a]) * (px[c] - px[a])
    end
    --- Is d strictly inside the circumcircle of the counter-clockwise a, b, c?
    local function inCircle(a, b, c, d)
        local ax, ay = px[a] - px[d], py[a] - py[d]
        local bx, by = px[b] - px[d], py[b] - py[d]
        local cx2, cy2 = px[c] - px[d], py[c] - py[d]
        local det = (ax * ax + ay * ay) * (bx * cy2 - cx2 * by)
            - (bx * bx + by * by) * (ax * cy2 - cx2 * ay)
            + (cx2 * cx2 + cy2 * cy2) * (ax * by - bx * ay)
        return det > 1e-6
    end
    -- Who owns each directed edge: a * K + b -> the triangle with a -> b.
    local K = #px + 1
    local owner = {}
    local function own(i)
        local t = tris[i]
        for e = 1, 3 do owner[t[e] * K + t[e % 3 + 1]] = i end
    end
    for i = 1, #tris do own(i) end
    local n = #tris
    for _ = 1, 4 * n * n do
        local flipped = false
        for i = 1, n do
            local A = tris[i]
            for ai = 1, 3 do
                local a, b, c = A[ai], A[ai % 3 + 1], A[(ai + 1) % 3 + 1]
                local j = owner[b * K + a]
                if j and j ~= i then
                    local Bt = tris[j]
                    local d = Bt[1] + Bt[2] + Bt[3] - a - b
                    -- a b c and b a d share a -> b; the quad c a d b takes
                    -- c -> d when it is convex there.
                    if inCircle(a, b, c, d) and cross(c, a, d) > 0.0 and cross(d, b, c) > 0.0 then
                        owner[a * K + b], owner[b * K + a] = nil, nil
                        tris[i] = { c, a, d }
                        tris[j] = { d, b, c }
                        own(i)
                        own(j)
                        flipped = true
                        break
                    end
                end
            end
        end
        if not flipped then break end
    end
    return tris
end

--- Triangles merged into convex pieces: two pieces either side of a diagonal
--- become one wherever that one is convex (Hertel-Mehlhorn).
local function mergeConvex(px, py, tris)
    local function convex(cyc)
        local n = #cyc
        for i = 1, n do
            local a, b, c = cyc[(i - 2) % n + 1], cyc[i], cyc[i % n + 1]
            local cr = (px[b] - px[a]) * (py[c] - py[b]) - (py[b] - py[a]) * (px[c] - px[b])
            if cr < -1e-6 then return false end
        end
        return true
    end
    local pieces = {}
    for i, t in ipairs(tris) do pieces[i] = { t[1], t[2], t[3] } end
    local merged = true
    while merged do
        merged = false
        for i = 1, #pieces do
            local A = pieces[i]
            local ai = 1
            while A and ai <= #A do
                local a, b = A[ai], A[ai % #A + 1]
                local took = false
                for j = 1, #pieces do
                    local Bp = pieces[j]
                    if j ~= i and Bp then
                        local nb = #Bp
                        for bi = 1, nb do
                            if Bp[bi] == b and Bp[bi % nb + 1] == a then
                                -- A from b round to a, then B from after a to before b.
                                local cyc, na = {}, #A
                                for s = 0, na - 1 do cyc[#cyc + 1] = A[(ai + s) % na + 1] end
                                for s = 1, nb - 2 do cyc[#cyc + 1] = Bp[(bi + s) % nb + 1] end
                                if convex(cyc) then
                                    pieces[i], pieces[j] = cyc, false
                                    A, ai, took, merged = cyc, 0, true, true
                                end
                                break
                            end
                        end
                    end
                    if took then break end
                end
                ai = ai + 1
            end
        end
    end
    local out = {}
    for i = 1, #pieces do
        if pieces[i] then out[#out + 1] = pieces[i] end
    end
    return out
end

--- One piece of land: its corners, the lines it is cut to, its box, and its
--- support in every one of the AIM_DIRS directions.
local function landPiece(xs, ys)
    local L = polyLines(xs, ys, 0.0, 0.0, 0.0, {})
    local x0, y0, x1, y1 = polyBox(xs, ys)
    return { xs = xs, ys = ys, L = L, x0 = x0, y0 = y0, x1 = x1, y1 = y1, h = supportsOf(xs, ys) }
end

--- The land's convex pieces (see above).
--- @return table pieces { { xs, ys, L, x0, y0, x1, y1 }, ... }
local function landPieces()
    local M = BR.Config and BR.Config.Map
    local B = (M and M.InBounds and BR.PointInPolygon and type(M.Boundary) == 'table' and #M.Boundary >= 3)
        and M.Boundary or nil
    local W = (M and M.IsWater and type(M.Water) == 'table') and M.Water or nil
    if landCache.pieces and landCache.b == B and landCache.w == W then return landCache.pieces end
    local polys = {}
    if B then
        -- COUNTER-CLOCKWISE, and every boundary edge LAND_IN in; the diagonals
        -- between pieces stay where they are, so the pieces still meet.
        local n, px, py = #B, {}, {}
        local a2 = 0.0
        for i = 1, n do
            local j = (i % n) + 1
            a2 = a2 + B[i].x * B[j].y - B[j].x * B[i].y
        end
        for i = 1, n do
            local v = (a2 >= 0.0) and B[i] or B[n + 1 - i]
            px[i], py[i] = v.x, v.y
        end
        for _, cyc in ipairs(mergeConvex(px, py, delaunayFlip(px, py, earClip(px, py)))) do
            local L = {}
            for i = 1, #cyc do
                local u, v = cyc[i], cyc[(i % #cyc) + 1]
                local ex, ey = px[v] - px[u], py[v] - py[u]
                local len = math.sqrt(ex * ex + ey * ey)
                if len > 1e-9 then
                    local nx, ny = ey / len, -ex / len
                    local grow = (v == (u % n) + 1) and -LAND_IN or 0.0
                    L[#L + 1] = { nx, ny, nx * px[u] + ny * py[u] + grow, math.atan(ny, nx) }
                end
            end
            local xs, ys = polyHpi(L)
            if #xs >= 3 then polys[#polys + 1] = { xs, ys } end
        end
    else
        polys[1] = { { -LAND_FAR, LAND_FAR, LAND_FAR, -LAND_FAR }, { -LAND_FAR, -LAND_FAR, LAND_FAR, LAND_FAR } }
    end
    -- THE WATER CUT OUT: a piece a rectangle (LAND_IN wider) reaches into is
    -- replaced by its parts west and east of it, and south and north of it
    -- between those.
    for _, w in ipairs(W or {}) do
        local x0, x1 = w.minX - LAND_IN, w.maxX + LAND_IN
        local y0, y1 = w.minY - LAND_IN, w.maxY + LAND_IN
        local rect = { { -1.0, 0.0, -x0 }, { 1.0, 0.0, x1 }, { 0.0, -1.0, -y0 }, { 0.0, 1.0, y1 } }
        local kept = {}
        for _, pc in ipairs(polys) do
            local ix, iy = clipBy(pc[1], pc[2], rect)
            if #ix >= 3 and polyArea2(ix, iy) > 0.0 then
                for _, side in ipairs({
                    { { 1.0, 0.0, x0 } },
                    { { -1.0, 0.0, -x1 } },
                    { { -1.0, 0.0, -x0 }, { 1.0, 0.0, x1 }, { 0.0, 1.0, y0 } },
                    { { -1.0, 0.0, -x0 }, { 1.0, 0.0, x1 }, { 0.0, -1.0, -y1 } },
                }) do
                    local sx, sy = clipBy(pc[1], pc[2], side)
                    if #sx >= 3 and polyArea2(sx, sy) > 1e-9 then kept[#kept + 1] = { sx, sy } end
                end
            else
                kept[#kept + 1] = pc
            end
        end
        polys = kept
    end
    local pieces = {}
    for _, pc in ipairs(polys) do pieces[#pieces + 1] = landPiece(pc[1], pc[2]) end
    landCache.b, landCache.w, landCache.pieces = B, W, pieces
    return pieces
end

--- The land's convex pieces, as Storm control's plan searches them: each a
--- counter-clockwise corner list { xs, ys }. Copies -- what tools/test_storm.lua
--- holds against BR.StormOffMap, and walks its own search over.
--- @return table pieces
function BR.StormLand()
    local out = {}
    for k, pc in ipairs(landPieces()) do
        local xs, ys = {}, {}
        for i = 1, #pc.xs do xs[i], ys[i] = pc.xs[i], pc.ys[i] end
        out[k] = { xs = xs, ys = ys }
    end
    return out
end

--- THE POINT ON THE MAP NEAREST (x, y): itself when it is in a piece of land,
--- and otherwise the nearest point of the nearest piece -- exact, a convex piece
--- at a time.
--- @return number x, number y
local function landNearest(pieces, x, y)
    local bx, by, bd = x, y, math.huge
    for _, pc in ipairs(pieces) do
        local qx, qy = polyNearest(pc.xs, pc.ys, x, y)
        local d = (qx - x) ^ 2 + (qy - y) ^ 2
        if d < bd then bx, by, bd = qx, qy, d end
        if d == 0.0 then break end
    end
    return bx, by
end

--- A CONVEX SET OF CENTERS CUT TO THE LAND, as convex parts: the set itself,
--- whole, when the pieces of land it meets cover it -- no coastline or water
--- crosses it -- and otherwise its part in each piece. Cut to `extra` (the map
--- bounds' lines) first, when given. Each part { xs, ys, a2 (twice its area),
--- x0, y0, x1, y1 }.
local function cutToLand(pieces, Tx, Ty, extra)
    if extra and #Tx >= 3 then Tx, Ty = clipBy(Tx, Ty, extra) end
    if #Tx < 3 then return {} end
    local aT = polyArea2(Tx, Ty)
    if aT <= AIM_AREA_MIN then return {} end
    local x0, y0, x1, y1 = polyBox(Tx, Ty)
    local parts, covered = {}, 0.0
    for k = 1, #pieces do
        local pc = pieces[k]
        if pc.x0 <= x1 and pc.x1 >= x0 and pc.y0 <= y1 and pc.y1 >= y0 then
            local Cx, Cy = clipBy(Tx, Ty, pc.L)
            if #Cx >= 3 then
                local a2 = polyArea2(Cx, Cy)
                if a2 > 0.0 then covered = covered + a2 end
                if a2 > AIM_AREA_MIN then
                    local bx0, by0, bx1, by1 = polyBox(Cx, Cy)
                    parts[#parts + 1] = { xs = Cx, ys = Cy, a2 = a2, x0 = bx0, y0 = by0, x1 = bx1, y1 = by1 }
                end
            end
            if Cx == Tx then break end
        end
    end
    if covered >= aT - AIM_COVER then
        return { { xs = Tx, ys = Ty, a2 = aT, x0 = x0, y0 = y0, x1 = x1, y1 = y1 } }
    end
    return parts
end

--- A binary heap of search states, least first by `before`.
local function heapPush(H, s, before)
    local i = #H + 1
    H[i] = s
    while i > 1 do
        local up = i // 2
        if before(H[i], H[up]) then
            H[i], H[up] = H[up], H[i]
            i = up
        else
            break
        end
    end
end

local function heapPop(H, before)
    local n = #H
    local top = H[1]
    H[1] = H[n]
    H[n] = nil
    n = n - 1
    local i = 1
    while true do
        local l, r, m = 2 * i, 2 * i + 1, i
        if l <= n and before(H[l], H[m]) then m = l end
        if r <= n and before(H[r], H[m]) then m = r end
        if m == i then break end
        H[i], H[m] = H[m], H[i]
        i = m
    end
    return top
end

--- A corner list cut to chords: every corner of it a point ON the shape, so the
--- polygon is inside it, at most `sag` in. Relative to (ox, oy), counter-clockwise.
local function chordPoly(ks, sag, ox, oy)
    local xs, ys = {}, {}
    for i = 1, #ks do
        local k = ks[i]
        if k.rho > 0.0 then
            local turn = k.a1 - k.a0
            local step = 2.0 * math.acos(math.max(-1.0, 1.0 - sag / k.rho))
            local m = math.max(1, math.ceil(turn / step))
            for j = 0, m do
                local th = k.a0 + turn * j / m
                xs[#xs + 1] = k.x + k.rho * math.cos(th) - ox
                ys[#ys + 1] = k.y + k.rho * math.sin(th) - oy
            end
        else
            xs[#xs + 1], ys[#ys + 1] = k.x - ox, k.y - oy
        end
    end
    return polyTidy(xs, ys)
end

--- THE ROOM A ZONE HAS IN THE ONE BEFORE: the offsets (from the host's center)
--- its center may take with every one of its discs at least `clear` inside the
--- host's chords -- the chord polygon eroded by the zone, edge by edge, by the
--- zone's exact support in that edge's normal.
local function roomOf(hx, hy, D, clear)
    local L = polyLines(hx, hy, 0.0, 0.0, 0.0, {})
    for i = 1, #L do
        local l = L[i]
        local hD = -math.huge
        for k = 1, #D do
            local d = D[k]
            local v = l[1] * d.x + l[2] * d.y + d.r
            if v > hD then hD = v end
        end
        l[3] = l[3] - hD - clear
    end
    return polyHpi(L)
end

--- The half-planes keeping a zone's exact bounding box inside `aabb` -- `margin`
--- inside it, when given -- or nil when it is wider than the box on an axis (or
--- there is no box).
local function boxLinesOf(D, aabb, margin)
    if not aabb then return nil end
    margin = margin or 0.0
    local west, east, south, north = 0.0, 0.0, 0.0, 0.0
    for k = 1, #D do
        local d = D[k]
        west = math.max(west, -d.x + d.r)
        east = math.max(east, d.x + d.r)
        south = math.max(south, -d.y + d.r)
        north = math.max(north, d.y + d.r)
    end
    local x0, x1 = aabb.min.x + west + margin, aabb.max.x - east - margin
    local y0, y1 = aabb.min.y + south + margin, aabb.max.y - north - margin
    if x0 > x1 or y0 > y1 then return nil end
    return {
        { -1.0, 0.0, -x0, math.pi },
        { 1.0, 0.0, x1, 0.0 },
        { 0.0, -1.0, -y0, -0.5 * math.pi },
        { 0.0, 1.0, y1, 0.5 * math.pi },
    }
end

--- Is (x, y) inside a box's half-planes, exactly?
local function inBox(bl, x, y)
    for i = 1, 4 do
        local l = bl[i]
        if l[1] * x + l[2] * y > l[3] then return false end
    end
    return true
end

--- A polygon cut to a box's half-planes; the empty polygon when they miss.
local function polyBoxed(xs, ys, bl)
    if #xs < 3 then
        local ok = true
        for k = 1, #xs do
            for i = 1, 4 do
                if lineOut(bl[i], xs[k], ys[k]) then ok = false end
            end
        end
        if ok then return xs, ys end
        return {}, {}
    end
    local L = polyLines(xs, ys, 0.0, 0.0, 0.0, {})
    for i = 1, 4 do L[#L + 1] = bl[i] end
    return polyHpi(L)
end

--- WHERE STORM CONTROL'S STORM GOES (#396): every circle from phase `from` to the
--- last, toward the spot (tx, ty), by the rules in the block above.
---
--- The host of phase `from` is the zone at (cx, cy, r) -- the next circle on the
--- map, or the outline a dev path re-entered from (`mo`); every later host is the
--- zone before at its own radius. Asks nothing of any stream.
--- @param seed number    the match's storm seed
--- @param from integer   the first phase to place
--- @param cx number      the host's center and radius
--- @param cy number
--- @param r number
--- @param mo table|nil   the host's outline, on a dev path
--- @param tx number      the spot as picked
--- @param ty number
--- @return table plan  { x, y (as picked), sx, sy (as aimed: on the map),
---                       ex, ey (where the storm ends), from,
---                       path = { [from - 1 .. last] = { x, y, r } },
---                       slack (how far inside the reach the end was held:
---                       0 when it is the exact nearest point),
---                       plain (true only when the plain walk stood in),
---                       opened, sets (the search's routes opened and the
---                       most sets a phase of the walk weighed), and
---                       capped, narrowed (true only when one of the two
---                       met its bound) }
function BR.StormAimPlan(seed, from, cx, cy, r, mo, tx, ty)
    local S = BR.Config and BR.Config.Storm
    local phases = S and S.phases or {}
    local N = #phases
    local aabb = S and S.mapAABB or nil
    local plan = { x = tx, y = ty, from = from, path = { [from - 1] = { x = cx, y = cy, r = r } } }
    local pieces = landPieces()
    local sx, sy = tx, ty
    if BR.StormOffMap(tx, ty) then sx, sy = landNearest(pieces, tx, ty) end
    plan.sx, plan.sy = sx, sy
    if from > N then
        plan.ex, plan.ey = cx, cy
        return plan
    end

    -- THE ROOM EACH PHASE HAS, as offsets from the center of the zone before.
    local room, box, bounds, disc = {}, {}, {}, {}
    for p = from, N do
        local host, ox, oy, hr
        if p == from then
            host, ox, oy, hr = BR.StormHost(seed, p, cx, cy, r, mo), cx, cy, r
        else
            hr = phases[p - 1].radius
            host, ox, oy = BR.StormHost(seed, p, 0.0, 0.0, hr, nil), 0.0, 0.0
        end
        local hx, hy = chordPoly(hostHull(host, ox, oy, hr), math.max(AIM_SAG_MIN, AIM_SAG * hr), ox, oy)
        local D = zoneDiscs(BR.StormUnit(seed, p), phases[p].radius)
        local px, py = roomOf(hx, hy, D, AIM_CLEAR)
        -- A HOST THAT CANNOT HOLD THE NEXT ZONE ANYWHERE (a dev path's outline)
        -- leaves the center where it is, as the planner does.
        if #px < 3 then px, py = { 0.0 }, { 0.0 } end
        room[p] = { px, py }
        -- The bounds as the planner tests them, and a millimeter inside them as
        -- the plan cuts its centers to, so none balances on the line.
        bounds[p] = boxLinesOf(D, aabb)
        box[p] = boxLinesOf(D, aabb, NEST_CLEAR)
        disc[p] = D
    end
    local back = {}
    for p = from, N do
        local ax, ay = room[p][1], room[p][2]
        local nx, ny = {}, {}
        for i = 1, #ax do nx[i], ny[i] = -ax[i], -ay[i] end
        back[p] = { nx, ny }
    end

    -- WHAT EACH PHASE'S PLACEMENT CAN STILL ADD, ignoring the land: the rooms
    -- after it summed, as their support in AIM_DIRS directions. The storm cannot
    -- end nearer the spot from a set of centers than that set plus them, and that
    -- sum is inside the lines the two supports add to -- the search's bound.
    local hRoom = {}
    for p = from, N do hRoom[p] = supportsOf(room[p][1], room[p][2]) end
    local after = { [N] = {} }
    for d = 1, AIM_DIRS do after[N][d] = 0.0 end
    for p = N - 1, from - 1, -1 do
        local h = {}
        for d = 1, AIM_DIRS do h[d] = after[p + 1][d] + hRoom[p + 1][d] end
        after[p] = h
    end
    -- The spot along every direction, and the pieces of land nearest it first,
    -- for the bound below.
    local spotAlong = {}
    for d = 1, AIM_DIRS do spotAlong[d] = DIR_C[d] * sx + DIR_S[d] * sy end
    local byNear = {}
    for k = 1, #pieces do
        local pc = pieces[k]
        byNear[k] = { pc = pc, d = polyDist(pc.xs, pc.ys, sx, sy) }
    end
    table.sort(byNear, function(a, b) return a.d < b.d end)
    --- How near the spot the storm could end from the centers (xs, ys) of phase
    --- p, at best, in two steps, the second only for a set the first leaves in
    --- the running: `alongOf`, how far the spot is outside the lines bounding
    --- them plus the rooms after (and those lines, `h`); and `landOf`, how near
    --- it the LAND inside the polygon every AIM_LENS-th of those lines closes
    --- comes -- the end is on land -- or math.huge when none is.
    local function alongOf(xs, ys, p)
        local hS = supportsOf(xs, ys)
        local hA = after[p]
        local h = {}
        local lb = 0.0
        for d = 1, AIM_DIRS do
            h[d] = hS[d] + hA[d]
            local g = spotAlong[d] - h[d]
            if g > lb then lb = g end
        end
        return lb, h
    end
    local function landOf(h)
        local Xx, Xy = supportPoly(h, AIM_LENS)
        local lb = math.huge
        for _, e in ipairs(byNear) do
            if e.d >= lb then break end
            local pc = e.pc
            -- APART when the piece is wholly past one of the polygon's lines.
            local apart = false
            for d = 1, AIM_DIRS, AIM_LENS do
                if -pc.h[OPPOSITE[d]] > h[d] then
                    apart = true
                    break
                end
            end
            if not apart then
                local Cx, Cy = clipBy(Xx, Xy, pc.L)
                if #Cx >= 1 then
                    local d = polyDist(Cx, Cy, sx, sy)
                    if d < lb then lb = d end
                end
            end
        end
        return lb
    end

    -- THE REACH WITHOUT THE LAND, forward from the host's center (each phase's
    -- room added on, by the same support lines): a few of its lines -- every
    -- AIM_LENS-th direction, the four axes among them -- are where the backward
    -- reach below is cut, since no center outside them is reached at all. And
    -- THE MAP BOUNDS from the first phase any placement the rules allow fits them.
    local boxAts, lens = {}, {}
    do
        local acc = {}
        for d = 1, AIM_DIRS do acc[d] = DIR_C[d] * cx + DIR_S[d] * cy end
        for p = from, N do
            for d = 1, AIM_DIRS do acc[d] = acc[d] + hRoom[p][d] end
            local L = {}
            for d = 1, AIM_DIRS, AIM_LENS do L[#L + 1] = { DIR_C[d], DIR_S[d], acc[d] } end
            lens[p] = L
            if box[p] then
                local Rx, Ry = supportPoly(acc)
                local bx, by = polyBoxed(Rx, Ry, box[p])
                if #bx >= 3 and polyArea2(bx, by) > 2.0 then boxAts[#boxAts + 1] = p end
            end
        end
    end

    -- HELD TO THE PLANNER'S OWN TESTS, every center: nested by the real fit, on
    -- the map, and inside the bounds whenever the planner would ask it (the zone
    -- before, at its own center, fits them).
    local function holds(pth)
        for p = from, N do
            local prev, c = pth[p - 1], pth[p]
            local hr = (p == from) and r or phases[p - 1].radius
            local host = BR.StormHost(seed, p, prev.x, prev.y, hr, (p == from) and mo or nil)
            local hks = hostHull(host, prev.x, prev.y, hr)
            if #room[p][1] >= 3 and BR.StormShape.fit(hks, disc[p], c.x, c.y, 1.0) > -NEST_CLEAR then
                return false
            end
            if BR.StormOffMap(c.x, c.y) then return false end
            local bl = bounds[p]
            if bl and inBox(bl, prev.x, prev.y) and not inBox(bl, c.x, c.y) then return false end
        end
        return true
    end

    --- THE ROUTE TO THE NEAREST END ON LAND: a best-first search over which
    --- convex set of land each phase's center stands in. Along one such route the
    --- centers a phase can take are convex -- the last phase's, plus its room, cut
    --- to the land (cutToLand) -- so the ends a route reaches are one convex set
    --- and its nearest point to the spot is exact; and no route ends nearer the
    --- spot than the land inside its centers plus the rooms after them (alongOf,
    --- landOf). So once no route left can end nearer than the best end found, that
    --- end is as near the spot as any storm the rules allow can end, every center
    --- on land. Ties go to the deeper route. `boxAt` is the phase held to the
    --- map bounds.
    local function search(boxAt)
        local function less(a, b)
            if a.key ~= b.key then return a.key < b.key end
            return a.p > b.p
        end
        local H, best = {}, nil
        heapPush(H, { p = from - 1, xs = { cx }, ys = { cy }, key = 0.0, stage = 0 }, less)
        while #H > 0 do
            local s = heapPop(H, less)
            -- NOTHING LEFT CAN END NEARER (a micrometer is a tie): the best end.
            -- Nor on land at all: none.
            if best and s.key >= best.near - AIM_TIE then return best end
            if s.key == math.huge then return best end
            if s.stage < 2 then
                -- ITS BOUND, a step each time it is the best on the heap.
                local lb
                if s.stage == 0 then
                    lb, s.h = alongOf(s.xs, s.ys, s.p)
                else
                    lb = landOf(s.h)
                    s.h = nil
                end
                s.stage = s.stage + 1
                if lb > s.key then s.key = lb end
                heapPush(H, s, less)
                s = nil
            end
            if s then
                if plan.opened >= AIM_OPEN_MAX then
                    plan.capped = true
                    return best
                end
                plan.opened = plan.opened + 1
                local q = s.p + 1
                local Tx, Ty = polySum(s.xs, s.ys, room[q][1], room[q][2])
                for _, c in ipairs(cutToLand(pieces, Tx, Ty, (q == boxAt) and box[q] or nil)) do
                    local kid = { p = q, xs = c.xs, ys = c.ys, parent = s, key = s.key, stage = 0 }
                    if q == N then
                        kid.near = polyDist(c.xs, c.ys, sx, sy)
                        if not best or kid.near < best.near then best = kid end
                    elseif not best or s.key < best.near - AIM_TIE then
                        heapPush(H, kid, less)
                    end
                end
            end
        end
        return best
    end

    --- The walk to the route's end: the spot when it is in the route's last set,
    --- else its nearest point -- held `slackE` inside the set (the set drawn in by
    --- it all round, or with `pull`, the nearest point moved that far toward its
    --- middle if that is nearer the spot). Then
    --- THE BACKWARD REACH ON LAND -- every center each phase may take, on land,
    --- and still end there over land: the end less the next phase's room, cut to
    --- the land and to the forward reach's lines, and so on back, a union of
    --- convex sets (one inside another dropped) -- and TOWARD THE SPOT, a phase at
    --- a time: the center nearest it among those the room allows and that reach
    --- still ends from, each set drawn in by a slack that halves every phase, so
    --- each center leaves the next one room.
    local function walkTo(best, boxAt, slackE, pull)
        local Lx, Ly = best.xs, best.ys
        -- HELD IN: the nearest point of the set drawn in by slackE all round.
        local Ex, Ey = polyHpi(polyLines(Lx, Ly, 0.0, 0.0, -slackE, {}))
        if #Ex < 3 then Ex, Ey = Lx, Ly end
        local ex, ey = polyNearest(Ex, Ey, sx, sy)
        if pull then
            -- OR PULLED IN, whichever is nearer the spot: the nearest point of
            -- the set moved slackE toward its middle -- what a sharp corner of
            -- the set, drawn in, would carry much further.
            local px, py = polyNearest(Lx, Ly, sx, sy)
            local mx, my = 0.0, 0.0
            for i = 1, #Lx do mx, my = mx + Lx[i], my + Ly[i] end
            mx, my = mx / #Lx - px, my / #Lx - py
            local m = math.sqrt(mx * mx + my * my)
            if m > 0.0 then
                local t = math.min(slackE, m) / m
                px, py = px + mx * t, py + my * t
            end
            if (px - sx) ^ 2 + (py - sy) ^ 2 < (ex - sx) ^ 2 + (ey - sy) ^ 2 then ex, ey = px, py end
        end
        local V = { [N] = { { xs = { ex }, ys = { ey } } } }
        local route = {}
        local s = best
        while s and s.p >= from do
            route[s.p] = s
            s = s.parent
        end
        --- The route's own centers at phase p that still end there, from its own
        --- at p + 1.
        local function routeStep(nxt, p)
            local Tx, Ty = polySum(nxt.xs, nxt.ys, back[p + 1][1], back[p + 1][2])
            local L = polyLines(route[p].xs, route[p].ys, 0.0, 0.0, 0.0, {})
            if p == boxAt then for i = 1, 4 do L[#L + 1] = box[p][i] end end
            if #Tx >= 3 then polyLines(Tx, Ty, 0.0, 0.0, 0.0, L) end
            local Cx, Cy = polyHpi(L)
            if #Cx < 3 then Cx, Cy = route[p].xs, route[p].ys end
            local x0, y0, x1, y1 = polyBox(Cx, Cy)
            return { xs = Cx, ys = Cy, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
        end
        -- The route's own centers that still end there, phase by phase back
        -- from the end, as far as any phase has needed them.
        local routeV = { [N] = V[N][1] }
        for p = N - 1, from, -1 do
            local cut = lens[p]
            if p == boxAt then
                cut = {}
                for i = 1, #lens[p] do cut[i] = lens[p][i] end
                for i = 1, 4 do cut[#cut + 1] = box[p][i] end
            end
            local list, kept = {}, {}
            for _, v in ipairs(V[p + 1]) do
                local Tx, Ty = polySum(v.xs, v.ys, back[p + 1][1], back[p + 1][2])
                for _, c in ipairs(cutToLand(pieces, Tx, Ty, cut)) do list[#list + 1] = c end
            end
            -- ONE INSIDE ANOTHER adds nothing.
            table.sort(list, function(a, b) return a.a2 > b.a2 end)
            for _, c in ipairs(list) do
                local inside = false
                for _, o in ipairs(kept) do
                    if c.x0 >= o.x0 and c.x1 <= o.x1 and c.y0 >= o.y0 and c.y1 <= o.y1 then
                        inside = true
                        for i = 1, #c.xs do
                            if not polyInside(o.xs, o.ys, c.xs[i], c.ys[i], AIM_IN) then
                                inside = false
                                break
                            end
                        end
                        if inside then break end
                    end
                end
                if not inside then kept[#kept + 1] = c end
            end
            plan.sets = math.max(plan.sets or 0, #kept)
            if #kept > AIM_SETS_MAX then
                -- MORE SETS THAN A WALK SHOULD WEIGH: the ones nearest the spot,
                -- and the route the search found -- its own centers that still
                -- end there, so the walk always has one.
                plan.narrowed = true
                for _, c in ipairs(kept) do c.near = polyDist(c.xs, c.ys, sx, sy) end
                table.sort(kept, function(a, b) return a.near < b.near end)
                for i = #kept, AIM_SETS_MAX, -1 do kept[i] = nil end
                for q = N - 1, p, -1 do
                    if not routeV[q] then routeV[q] = routeStep(routeV[q + 1], q) end
                end
                kept[#kept + 1] = routeV[p]
            end
            V[p] = kept
        end
        local path = { [from - 1] = plan.path[from - 1] }
        local px, py = cx, cy
        local slack = slackE
        for p = from, N - 1 do
            slack = slack * 0.5
            local ax, ay = room[p][1], room[p][2]
            local qx, qy
            if #ax < 3 then
                qx, qy = px, py
            else
                local wx0, wy0, wx1, wy1 = polyBox(ax, ay)
                wx0, wy0, wx1, wy1 = wx0 + px, wy0 + py, wx1 + px, wy1 + py
                local bd = math.huge
                for pass = 1, 2 do
                    for _, v in ipairs(V[p]) do
                        if v.x0 <= wx1 and v.x1 >= wx0 and v.y0 <= wy1 and v.y1 >= wy0 then
                            local L = polyLines(ax, ay, px, py, 0.0, {})
                            polyLines(v.xs, v.ys, 0.0, 0.0, (pass == 1) and -slack or AIM_TAU, L)
                            local Qx, Qy = polyHpi(L)
                            if #Qx >= 3 then
                                local nx, ny
                                if pass == 1 then
                                    nx, ny = polyNearest(Qx, Qy, sx, sy)
                                else
                                    -- NO ROOM TO SPARE: the middle of what is left.
                                    nx, ny = 0.0, 0.0
                                    for i = 1, #Qx do nx, ny = nx + Qx[i], ny + Qy[i] end
                                    nx, ny = nx / #Qx, ny / #Qx
                                end
                                local d = (nx - sx) ^ 2 + (ny - sy) ^ 2
                                if d < bd then qx, qy, bd = nx, ny, d end
                            end
                        end
                    end
                    if qx then break end
                end
                -- NOTHING LEFT AT ALL (rounding): stay, and let the planner's
                -- tests below judge the walk.
                if not qx then qx, qy = px, py end
            end
            path[p] = { x = qx, y = qy, r = phases[p].radius }
            px, py = qx, qy
        end
        path[N] = { x = ex, y = ey, r = phases[N].radius }
        return path, ex, ey
    end

    -- THE SEARCH, with the bounds held at the first phase they can be on land
    -- (and, should no route on land fit them there, the next).
    local best, boxAt = nil, nil
    plan.opened = 0
    for i = 1, #boxAts + 1 do
        boxAt = boxAts[i]
        best = search(boxAt)
        if best then break end
    end

    -- THE WALK, held to the planner's tests: to the exact end first, and where
    -- that end is on the very edge of the reach -- one chain reaches it, and the
    -- walk balances on it -- to an end held AIM_SLACK inside, then twenty
    -- centimeters, then two meters; `slack` says how far. A plan nothing saves
    -- -- never, over the fuzz in tools/test_storm.lua -- is replaced by the plain
    -- walk (`plain`): each center the nearest the spot on land its room allows,
    -- which ends wherever that walk does.
    if best then
        for _, try in ipairs({ { 0.0 }, { AIM_SLACK, true }, { 10.0 * AIM_SLACK }, { 100.0 * AIM_SLACK } }) do
            local path, ex, ey = walkTo(best, boxAt, try[1], try[2])
            if holds(path) then
                plan.path, plan.ex, plan.ey, plan.slack = path, ex, ey, try[1]
                return plan
            end
        end
    end
    plan.plain = true
    local path = { [from - 1] = plan.path[from - 1] }
    local px, py = cx, cy
    for p = from, N do
        local ax, ay = room[p][1], room[p][2]
        local qx, qy, qd = px, py, math.huge
        if #ax >= 3 then
            local Tx, Ty = {}, {}
            for i = 1, #ax do Tx[i], Ty[i] = ax[i] + px, ay[i] + py end
            if bounds[p] and inBox(bounds[p], px, py) then Tx, Ty = clipBy(Tx, Ty, box[p]) end
            for k = 1, #pieces do
                local Cx, Cy = clipBy(Tx, Ty, pieces[k].L)
                if #Cx >= 3 then
                    local nx, ny = polyNearest(Cx, Cy, sx, sy)
                    local d = (nx - sx) ^ 2 + (ny - sy) ^ 2
                    if d < qd then qx, qy, qd = nx, ny, d end
                end
            end
        end
        path[p] = { x = qx, y = qy, r = phases[p].radius }
        px, py = qx, qy
    end
    plan.path, plan.ex, plan.ey = path, px, py
    return plan
end

--- Choose where the next zone goes: its centre, by its REAL SHAPE.
---
---   "the circles still overlap when they are different shapes."
---                                                    -- the owner, 2026-09-23
---
--- ═══ NESTED: THE NEXT ZONE LIES ENTIRELY INSIDE THIS ONE ═══
---
--- The centres the next zone can take and still fit are F = {c : D + c inside Z},
--- which is Z eroded by D: CONVEX, and it holds this zone's own centre with room to
--- spare, because blobUnit drew the next zone to fit there concentric (`fitClear`).
--- So along a drawn bearing the feasible offsets are one interval from zero, and
--- its far end L is found by bisection on the exact test -- every disc of D inside
--- Z, BR.StormShape.fit. The offset is sqrt(u) * edgeBias * L: uniform over F when
--- F is a disc, which is exactly what rng:pointInDisc drew in the circle era.
---
--- ═══ A BREAKOUT: THE GAP TO THIS ZONE, CAPPED ═══
---
--- A breakout may leave this zone entirely, and the gap between the two shapes is
--- capped at `gapMax` of the current radius, as it always was (user call,
--- 2026-08-06). The gap between Z and D + c is the signed distance from c to the
--- Minkowski sum Z + (-D), which is a corner list (BR.StormShape.sumOf) -- so the
--- breakout's region F_b is that sum dilated by the gap, convex, containing F, and
--- the same bisection finds its far end on the bearing. A breakout roll can still
--- land nested, as it always could.
---
--- ═══ THE DRAWS ARE FIXED, AND THEY ARE THE ONES pointInDisc TOOK ═══
---
--- The breakout roll -- only when there is a chance and this zone is at least the
--- floor, the rule this always had -- then the bearing, then u. Everything after is
--- arithmetic with fixed iteration counts. So a phase takes the same values off
--- m.stormRng that it took when zones were circles, and `first.stream`'s alignment
--- of warmup and phase 1 holds. (The one conditional draw the circle era had -- a
--- random bearing for an offset of exactly zero -- is gone: the bearing is always
--- drawn.)
---
--- ═══ THE EDGE HUG, THE MAP BOUNDS AND THE WATER, BY REAL SHAPE ═══
---
--- THE LAST PHASES HUG THE EDGE: with `hugM`, the offset is at least the nested
--- ray's far end less hugM -- the ray standing in for the old slack.
---
--- THE MAP BOUNDS clamp the centre so the next zone's exact bounding box stays
--- inside mapAABB, an axis it is wider than being centred -- ClampCircleToAABB's
--- rule, for a shape. If that moved it out of the phase's region, it is bisected
--- back toward this zone's centre to the last point inside: THE PHASE'S BUDGET
--- BEATS BOUNDS, because the sweep was priced off where the solver put the zone.
---
--- AND NOT OFF THE MAP: the centre walks back toward this zone's in eight steps, as
--- it always did, and the region is convex, so every step of the walk is inside it.
---
--- A HOST THAT CANNOT HOLD THE NEXT ZONE AT ALL -- a frozen outline thawed, or a
--- same-phase `brphase`, part way through a morph -- leaves the centre where it is,
--- and the phase is simply not nested. Those are dev paths.
---
--- @param rng table        m.stormRng (server only: clients must not predict this)
--- @param host table       the zone being closed from, as a shape (BR.StormHost)
--- @param cx number        its centre
--- @param cy number
--- @param r0 number        its radius: the breakout's gap and floor are measured in it
--- @param unit table|nil   the next zone's unit; nil for a point
--- @param r1 number        the next zone's radius
--- @param edgeBias number  0..1, how much of the room the offset may use
--- @param aabb table|nil   playable bounds
--- @param hugM number|nil  the edge hug, on the phases that have one
--- @param breakout table|nil  { chance, gapMax, minRadius }
--- @return number, number, boolean  the next centre, and whether it rolled a breakout
function BR.NextZoneCentre(rng, host, cx, cy, r0, unit, r1, edgeBias, aabb, hugM, breakout)
    local SS = BR.StormShape
    local hks = hostHull(host, cx, cy, r0)
    local D0 = zoneDiscs(unit, r1)

    local broke = false
    if breakout and breakout.chance and breakout.chance > 0
       and r0 >= (breakout.minRadius or 0.0) then
        if rng:float() < breakout.chance then broke = true end
    end
    local theta = rng:float() * 2.0 * math.pi
    local u = rng:float()

    -- A config value above 1.0 would push the new centre past the region and
    -- silently overshoot it, so clamp rather than trusting it.
    edgeBias = BR.Clamp(edgeBias or 0.55, 0.0, 1.0)
    local dx, dy = math.cos(theta), math.sin(theta)

    local function nested(x, y)
        return SS.fit(hks, D0, x, y, 1.0) <= -NEST_CLEAR
    end
    local inside = nested
    local sum, gap = nil, 0.0
    if broke then
        sum = SS.sumOf(hks, SS.reflect(SS.discHull(D0)))
        gap = (breakout.gapMax or 0.5) * r0
        inside = function(x, y) return SS.hullDistance(sum, x, y) <= gap end
    end

    --- The far end of the region along the drawn bearing: zero when this zone's own
    --- centre is not in it.
    local function ray(ok, hi)
        if not ok(cx, cy) then return 0.0 end
        local lo = 0.0
        for _ = 1, RAY_STEPS do
            local mid = 0.5 * (lo + hi)
            if ok(cx + dx * mid, cy + dy * mid) then lo = mid else hi = mid end
        end
        return lo
    end

    -- A NESTED CENTRE IS INSIDE THIS ZONE -- every zone holds its own centre -- so no
    -- ray reaches past this zone's reach from its centre. A breakout's reaches no
    -- further than the sum's, plus the gap.
    local Ln = ray(nested, SS.reachOf(hks, cx, cy) + 1.0)
    local L = Ln
    if broke then L = ray(inside, SS.reachOf(sum, cx, cy) + gap + 1.0) end

    local s = math.sqrt(u) * edgeBias * L
    if hugM then
        local floor = Ln - hugM
        if floor > s then s = floor end
        if s > L then s = L end
    end
    local nx, ny = cx + dx * s, cy + dy * s

    if aabb then
        -- THE NEXT ZONE'S EXACT BOUNDING BOX about its centre: its support function in
        -- the four axis directions.
        local west, east, south, north = 0.0, 0.0, 0.0, 0.0
        for k = 1, #D0 do
            local d = D0[k]
            west = math.max(west, -d.x + d.r)
            east = math.max(east, d.x + d.r)
            south = math.max(south, -d.y + d.r)
            north = math.max(north, d.y + d.r)
        end
        local minX, maxX = aabb.min.x + west, aabb.max.x - east
        local minY, maxY = aabb.min.y + south, aabb.max.y - north
        local mx, my
        -- If the zone is wider than the box, centring it is the best we can do.
        if minX > maxX then
            mx = 0.5 * (aabb.min.x + aabb.max.x) + 0.5 * (west - east)
        else
            mx = BR.Clamp(nx, minX, maxX)
        end
        if minY > maxY then
            my = 0.5 * (aabb.min.y + aabb.max.y) + 0.5 * (south - north)
        else
            my = BR.Clamp(ny, minY, maxY)
        end

        -- Clamping to the map bounds can push the centre out of the region the phase
        -- settled on -- most easily when this zone already overhangs the bounds,
        -- which the opening zone routinely does.
        --
        -- THE PHASE'S BUDGET WINS OVER BOUNDS. A zone poking into the ocean is a
        -- cosmetic problem; a zone further out than the phase intended is a run
        -- nobody was given time for, because the shrink duration was priced off the
        -- place the solver chose. So it is walked back along the line to this zone's
        -- centre, to the last point inside the region.
        if mx ~= nx or my ~= ny then
            if not inside(mx, my) then
                local lo = 0.0
                if inside(cx, cy) then
                    local hi = 1.0
                    for _ = 1, RAY_STEPS do
                        local mid = 0.5 * (lo + hi)
                        if inside(cx + (mx - cx) * mid, cy + (my - cy) * mid) then
                            lo = mid
                        else
                            hi = mid
                        end
                    end
                end
                mx, my = cx + (mx - cx) * lo, cy + (my - cy) * lo
            end
            nx, ny = mx, my
        end
    end

    -- AND NOT OFF THE MAP.
    --
    -- The anchor is a POI and therefore always on land, but nothing stopped
    -- the per-phase drift from walking seaward one zone at a time -- eight
    -- phases of offset off a coastal anchor is enough to finish over open water,
    -- and the final zone is where it matters most (user, 2026-08-06: "rare (but
    -- possible) cases where the storm can close in to an anchor point in the
    -- ocean").
    --
    -- Walked back along its own line toward the PREVIOUS centre, which is on
    -- the map by induction: phase 0 is the anchor POI, and every POI is inside
    -- the boundary (tools/check_boundary.lua is what makes that true rather
    -- than hoped). That makes this terminate, and it keeps the draw's bearing
    -- -- the zone still moves the way the roll said, just not as far. The region
    -- the centre was drawn in is convex and holds the previous centre, so every
    -- step in is still inside it: a nested zone stays nested.
    --
    -- THE CENTRE IS WHAT IS TESTED, and it is a good stand-in for the zone: it is
    -- the zone's centroid, at least 0.41 of r deep in every shape that ships, and it
    -- is phase 8's final point itself.
    --
    -- ═══ THE MASK IS THE SURVEYED BOUNDARY NOW, NOT JUST THE RECTANGLES ═══
    --
    -- It used to be BR.Config.Map.Water alone: five coarse rectangles authored
    -- to stop LOOT generating in the Pacific. They were never a map outline,
    -- and the gaps between them are where the storm went. Measured over 4000
    -- simulated matches on the old rule, 20.2% of them ENDED with the final
    -- circle's centre outside the playable shape -- which is the owner's report
    -- ("we have too many places where the storm can end outside the map and in
    -- the ocean", 2026-08-28) as a number rather than as an anecdote.
    --
    -- BOTH TESTS RUN, because neither contains the other. The boundary is the
    -- island's outline and knows nothing about the water inside it; the Alamo
    -- Sea rectangle sits wholly within the ring and is the case the boundary
    -- cannot catch. The four ocean rectangles are wholly outside it and are now
    -- redundant here -- kept because they cost one comparison and because
    -- deleting a backstop to save a comparison is how backstops go missing.
    -- (BR.StormOffMap, the one spelling every circle Storm control places is
    -- held to too.)
    local offMap = BR.StormOffMap

    if offMap(nx, ny) then
        for attempt = 1, 8 do
            local t = 1.0 - attempt / 8.0
            local tx, ty = cx + (nx - cx) * t, cy + (ny - cy) * t
            if not offMap(tx, ty) then
                return tx, ty, broke
            end
        end
        -- Every step of the way in was off the map, which means the CURRENT
        -- centre is too. Nothing better to offer than staying put.
        return cx, cy, broke
    end

    return nx, ny, broke
end

--- Build the record for a phase transition.
---
--- @param phase integer      phase index being entered (1-based)
--- @param cx0 number         circle we are starting from
--- @param cy0 number
--- @param r0 number
--- @param cx1 number         circle we are shrinking toward
--- @param cy1 number
--- @param r1 number
--- @param now number         server time
--- @param waitMs number
--- @param shrinkMs number
--- @param dps number
--- @param seed number|nil    the match's storm seed -- WHAT SHAPE THIS PHASE IS
--- @param mo table|nil       the wall's outline, for a record that starts part way
---                           through a morph; see the record's header
--- @return table
---
--- ═══ THE SEED DEFAULTS TO ZERO, AND ZERO IS A REAL SEED ═══
---
--- Every production path passes the match's own (server/storm.lua's enterPhase is
--- the only one), so this default is for a record built by hand: a test, or a
--- console. It is 0 rather than nil because nil would mean "no shape", and "no
--- shape" means circles -- so a caller that forgot the seed would quietly ship the
--- exact thing #344 exists to remove, with a green suite behind it. Seed 0 is an
--- ordinary stream and draws an ordinary blob, so a hand-built record is measured
--- against the same kind of shape the game draws.
function BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, r1, now, waitMs, shrinkMs, dps, seed, mo)
    return {
        phase   = phase,
        seed    = math.tointeger(math.floor(seed or 0)) or 0,
        -- ABSENT RATHER THAN EMPTY on every ordinary record, so the wire and the
        -- snapshot carry nothing new for the phases that start where they should.
        mo      = mo,
        cx0     = cx0 + 0.0,
        cy0     = cy0 + 0.0,
        r0      = r0 + 0.0,
        cx1     = cx1 + 0.0,
        cy1     = cy1 + 0.0,
        r1      = r1 + 0.0,
        tStart  = now + 0.0,
        tWait   = waitMs + 0.0,
        tShrink = shrinkMs + 0.0,
        dps     = dps + 0.0,
    }
end

--- Total ms from the start of a phase until its circle has fully collapsed.
function BR.StormPhaseDuration(rec)
    if not rec then return 0.0 end
    return rec.tWait + rec.tShrink
end
